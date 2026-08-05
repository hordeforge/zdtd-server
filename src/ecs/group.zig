//! Cached per-Kind dense slot lists (entt-style non-owning groups).
//!
//! Stock keeps the same shape: `World` holds the general `Entities` index plus
//! maintained per-type lists (`Players`, the EntityAlive list, the vehicle /
//! drone / turret trackers), added in `World::SpawnEntityInWorld` and removed in
//! `World::unloadEntity` (asm.il:1225261-1225262, :1234230/:1234384, :1233956/
//! :1234090). `World::GetPlayers()` just returns the cached list.
//!
//! Invariant: each kind's `dense[0..len]` is **strictly ascending**, so
//! iterating a group visits the same slots in the same order as the open
//! `0..max_entities` View scan. That makes group-driven loops byte-identical to
//! the scans they replace (nearest-player tie-breaks, capped despawn lists,
//! turret target selection all depend on slot order).
//!
//! Kind is immutable for an entity's lifetime (`world.zig` writes `kind[s]` only
//! in `spawnBase`), so a slot belongs to exactly one group and never migrates.
//! Maintenance therefore lives at the two points that write `alive[]`/`kind[]`:
//! `World.spawnBase` inserts, `World.destroy` removes (plus `World.reviveSlot`,
//! which is idempotent).
//!
//! No heap and no `World` import (avoids a dependency cycle): 7 x 512 x u16 = 7 KB.

const std = @import("std");
const ent = @import("entity.zig");
const c = @import("components.zig");

const Slot = ent.Slot;
const Kind = c.Kind;
const max_entities = ent.max_entities;
const n_kinds = @typeInfo(Kind).@"enum".fields.len;

fn orderSlot(key: Slot, item: Slot) std.math.Order {
    return std.math.order(key, item);
}

pub const Groups = struct {
    dense: [n_kinds][max_entities]Slot = .{.{0} ** max_entities} ** n_kinds,
    len: [n_kinds]u16 = .{0} ** n_kinds,

    /// Sorted insert. No-op when `slot` is already present (so `reviveSlot` and
    /// any double-spawn guard cannot duplicate an entry) or when the list is
    /// full (impossible: at most `max_entities` distinct slots exist).
    pub fn insert(self: *Groups, kind: Kind, slot: Slot) void {
        if (slot >= max_entities) return;
        const k = @intFromEnum(kind);
        const n = self.len[k];
        if (n >= max_entities) return;
        const at = std.sort.lowerBound(Slot, self.dense[k][0..n], slot, orderSlot);
        if (at < n and self.dense[k][at] == slot) return;
        std.mem.copyBackwards(Slot, self.dense[k][at + 1 .. n + 1], self.dense[k][at..n]);
        self.dense[k][at] = slot;
        self.len[k] = n + 1;
    }

    /// Sorted remove. No-op when absent, mirroring `World.destroy`'s idempotence.
    pub fn remove(self: *Groups, kind: Kind, slot: Slot) void {
        if (slot >= max_entities) return;
        const k = @intFromEnum(kind);
        const n = self.len[k];
        const at = std.sort.lowerBound(Slot, self.dense[k][0..n], slot, orderSlot);
        if (at >= n or self.dense[k][at] != slot) return;
        std.mem.copyForwards(Slot, self.dense[k][at .. n - 1], self.dense[k][at + 1 .. n]);
        self.len[k] = n - 1;
    }

    /// Ascending slots of this kind. Valid until the next spawn/destroy.
    pub fn slice(self: *const Groups, kind: Kind) []const Slot {
        const k = @intFromEnum(kind);
        return self.dense[k][0..self.len[k]];
    }

    pub fn count(self: *const Groups, kind: Kind) u16 {
        return self.len[@intFromEnum(kind)];
    }
};

fn isAscending(s: []const Slot) bool {
    var i: usize = 1;
    while (i < s.len) : (i += 1) if (s[i - 1] >= s[i]) return false;
    return true;
}

test "insert keeps strictly ascending order regardless of input order" {
    var g: Groups = .{};
    for ([_]Slot{ 7, 1, 300, 0, 42, 511, 8 }) |s| g.insert(.zombie, s);
    try std.testing.expectEqual(@as(u16, 7), g.count(.zombie));
    try std.testing.expect(isAscending(g.slice(.zombie)));
    try std.testing.expectEqualSlices(Slot, &.{ 0, 1, 7, 8, 42, 300, 511 }, g.slice(.zombie));
}

test "insert of an existing slot is a no-op" {
    var g: Groups = .{};
    g.insert(.player, 5);
    g.insert(.player, 9);
    g.insert(.player, 5);
    g.insert(.player, 9);
    try std.testing.expectEqualSlices(Slot, &.{ 5, 9 }, g.slice(.player));
}

test "remove first, middle and last preserves order" {
    var g: Groups = .{};
    for ([_]Slot{ 1, 2, 3, 4, 5 }) |s| g.insert(.turret, s);
    g.remove(.turret, 1);
    try std.testing.expectEqualSlices(Slot, &.{ 2, 3, 4, 5 }, g.slice(.turret));
    g.remove(.turret, 4);
    try std.testing.expectEqualSlices(Slot, &.{ 2, 3, 5 }, g.slice(.turret));
    g.remove(.turret, 5);
    try std.testing.expectEqualSlices(Slot, &.{ 2, 3 }, g.slice(.turret));
}

test "remove of an absent slot is a no-op" {
    var g: Groups = .{};
    g.remove(.vehicle, 3); // empty
    g.insert(.vehicle, 3);
    g.remove(.vehicle, 2);
    g.remove(.vehicle, 4);
    g.remove(.vehicle, 600); // out of range
    try std.testing.expectEqualSlices(Slot, &.{3}, g.slice(.vehicle));
}

test "kinds are independent" {
    var g: Groups = .{};
    g.insert(.zombie, 10);
    g.insert(.animal, 10);
    g.remove(.zombie, 10);
    try std.testing.expectEqual(@as(u16, 0), g.count(.zombie));
    try std.testing.expectEqualSlices(Slot, &.{10}, g.slice(.animal));
}

test "fill to capacity then drain" {
    var g: Groups = .{};
    // Descending inserts exercise the shift path on every step.
    var i: Slot = max_entities;
    while (i > 0) : (i -= 1) g.insert(.loot_bag, i - 1);
    try std.testing.expectEqual(@as(u16, max_entities), g.count(.loot_bag));
    try std.testing.expect(isAscending(g.slice(.loot_bag)));
    g.insert(.loot_bag, 0); // full + duplicate: still a no-op
    try std.testing.expectEqual(@as(u16, max_entities), g.count(.loot_bag));
    i = 0;
    while (i < max_entities) : (i += 1) {
        g.remove(.loot_bag, i);
        try std.testing.expectEqual(@as(u16, @intCast(max_entities - i - 1)), g.count(.loot_bag));
        try std.testing.expect(isAscending(g.slice(.loot_bag)));
    }
    try std.testing.expectEqual(@as(usize, 0), g.slice(.loot_bag).len);
}

test "group order matches an open ascending scan under random churn" {
    var g: Groups = .{};
    var present: [max_entities]bool = .{false} ** max_entities;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();
    var op: usize = 0;
    while (op < 4000) : (op += 1) {
        const s: Slot = rnd.uintLessThan(Slot, max_entities);
        if (rnd.boolean()) {
            g.insert(.trader, s);
            present[s] = true;
        } else {
            g.remove(.trader, s);
            present[s] = false;
        }
    }
    var expect_buf: [max_entities]Slot = undefined;
    var n: usize = 0;
    for (present, 0..) |p, i| {
        if (!p) continue;
        expect_buf[n] = @intCast(i);
        n += 1;
    }
    try std.testing.expectEqualSlices(Slot, expect_buf[0..n], g.slice(.trader));
}
