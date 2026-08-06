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

// ---------------------------------------------------------------------------
// Group face (cached dense per-Kind lists, see group.zig).
//
// View (everything above) is the default: an open `0..max_entities` scan that
// is always correct, including while the loop body spawns or destroys.
// Group is the cached alternative: same slots, same ascending order, but O(live)
// instead of O(capacity). It is only valid while nothing spawns or destroys.
// A loop that mutates the world must use `copyKindInto` or stay on the View.
// ---------------------------------------------------------------------------

/// Ascending alive slots of `kind`. Invalidated by the next spawn/destroy.
pub fn groupSlice(w: *const World, kind: Kind) []const Slot {
    return w.kind_groups.slice(kind);
}

/// Group walk that re-reads the length and re-checks `alive` each step, so a
/// body that destroys stays memory-safe. Visit order/completeness under such
/// mutation is unspecified: use `copyKindInto` when the body mutates.
pub fn forEachKindGroup(
    w: *World,
    kind: Kind,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), *World, Slot) void,
) void {
    var i: usize = 0;
    while (i < w.kind_groups.count(kind)) : (i += 1) {
        const s = w.kind_groups.slice(kind)[i];
        if (!w.alive[s]) continue;
        f(ctx, w, s);
    }
}

/// Snapshot the kind group into `out` (ascending). Returns the count written,
/// capped at `out.len`. For loops that spawn or destroy while iterating.
pub fn copyKindInto(w: *const World, kind: Kind, out: []Slot) usize {
    const src = w.kind_groups.slice(kind);
    const n = @min(src.len, out.len);
    @memcpy(out[0..n], src[0..n]);
    return n;
}

const std = @import("std");

/// Open View scan collecting alive slots of `kind`; the reference order the
/// group must reproduce.
fn viewCollect(w: *const World, kind: Kind, out: []Slot) usize {
    var n: usize = 0;
    var i: Slot = 0;
    while (i < max_entities and n < out.len) : (i += 1) {
        if (!w.alive[i] or !w.mask[i].kind or w.kind[i] != kind) continue;
        out[n] = i;
        n += 1;
    }
    return n;
}

fn expectGroupsMatchView(w: *const World) !void {
    var view_buf: [max_entities]Slot = undefined;
    var total: usize = 0;
    inline for (@typeInfo(Kind).@"enum".fields) |fld| {
        const k: Kind = @enumFromInt(fld.value);
        const n = viewCollect(w, k, &view_buf);
        try std.testing.expectEqualSlices(Slot, view_buf[0..n], groupSlice(w, k));
        try std.testing.expectEqual(@as(u32, @intCast(n)), w.countKind(k));
        total += n;
    }
    try std.testing.expectEqual(@as(usize, w.entity_count), total);
}

test "kind groups match the open View scan under spawn/destroy churn" {
    var w: World = .{};
    defer w.deinit();
    var prng = std.Random.DefaultPrng.init(0x5EED_1234);
    const rnd = prng.random();
    var op: usize = 0;
    while (op < 2000) : (op += 1) {
        switch (rnd.uintLessThan(u8, 6)) {
            0 => _ = w.spawnZombie(rnd.float(f32) * 100, 70, rnd.float(f32) * 100, 40),
            1 => _ = w.spawnPlayer(0, 70, 0, @intCast(rnd.uintLessThan(u8, 8))),
            2 => _ = w.spawnLootBag(1, 70, 1, 1, 1),
            3 => _ = w.spawnTurret(2, 70, 2),
            4 => _ = w.spawnAnimal(3, 70, 3, 30, 0, ""),
            else => {
                const s: Slot = rnd.uintLessThan(Slot, max_entities);
                if (w.alive[s]) w.destroy(s);
            },
        }
        if (op % 37 == 0) w.beginTick(); // exercise slot recycle
        try expectGroupsMatchView(&w);
    }
}

test "recycled slot appears exactly once, in the new kind only" {
    var w: World = .{};
    defer w.deinit();
    var i: usize = 0;
    while (i < 5) : (i += 1) _ = w.spawnZombie(@floatFromInt(i), 70, 0, 40);
    w.beginTick();
    w.destroy(2);
    try std.testing.expectEqualSlices(Slot, &.{ 0, 1, 3, 4 }, groupSlice(&w, .zombie));
    w.beginTick(); // clears freed_this_tick so slot 2 is reusable
    _ = w.spawnTurret(0, 70, 0);
    try std.testing.expectEqualSlices(Slot, &.{ 0, 1, 3, 4 }, groupSlice(&w, .zombie));
    try std.testing.expectEqualSlices(Slot, &.{2}, groupSlice(&w, .turret));
    try expectGroupsMatchView(&w);
}

test "reviveSlot is idempotent and never duplicates" {
    var w: World = .{};
    defer w.deinit();
    const id = w.spawnPlayer(0, 70, 0, 0).?;
    const s = w.slotOfNetId(id).?;
    w.reviveSlot(s);
    w.reviveSlot(s);
    try std.testing.expectEqualSlices(Slot, &.{s}, groupSlice(&w, .player));
    try std.testing.expectEqual(@as(u32, 1), w.countKind(.player));
    // A destroyed slot has a cleared mask: reviving it stays a no-op.
    w.destroy(s);
    w.reviveSlot(s);
    try std.testing.expectEqual(@as(usize, 0), groupSlice(&w, .player).len);
    try std.testing.expectEqual(@as(u16, 0), w.entity_count);
}

test "forEachKindGroup visits the same slots as forEachKind" {
    var w: World = .{};
    defer w.deinit();
    _ = w.spawnZombie(0, 70, 0, 40);
    _ = w.spawnPlayer(0, 70, 0, 0);
    _ = w.spawnZombie(1, 70, 0, 40);
    _ = w.spawnZombie(2, 70, 0, 40);
    w.destroy(2);
    const Acc = struct {
        buf: [max_entities]Slot = undefined,
        n: usize = 0,
        fn add(self: *@This(), _: *World, s: Slot) void {
            self.buf[self.n] = s;
            self.n += 1;
        }
    };
    var view: Acc = .{};
    var grp: Acc = .{};
    forEachKind(&w, .zombie, &view, Acc.add);
    forEachKindGroup(&w, .zombie, &grp, Acc.add);
    try std.testing.expectEqualSlices(Slot, view.buf[0..view.n], grp.buf[0..grp.n]);
}

test "copyKindInto snapshots ascending and caps at out.len" {
    var w: World = .{};
    defer w.deinit();
    var i: usize = 0;
    while (i < 4) : (i += 1) _ = w.spawnZombie(@floatFromInt(i), 70, 0, 40);
    var out: [max_entities]Slot = undefined;
    try std.testing.expectEqual(@as(usize, 4), copyKindInto(&w, .zombie, &out));
    try std.testing.expectEqualSlices(Slot, &.{ 0, 1, 2, 3 }, out[0..4]);
    var small: [2]Slot = undefined;
    try std.testing.expectEqual(@as(usize, 2), copyKindInto(&w, .zombie, &small));
    try std.testing.expectEqualSlices(Slot, &.{ 0, 1 }, &small);
    // The snapshot stays usable while the loop destroys through it.
    const n = copyKindInto(&w, .zombie, &out);
    for (out[0..n]) |s| w.destroy(s);
    try std.testing.expectEqual(@as(usize, 0), groupSlice(&w, .zombie).len);
}

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
    _ = w.spawnTrader("t", 1, 70, 1, 0, 50_000);
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
