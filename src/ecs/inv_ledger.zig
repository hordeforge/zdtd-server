//! P4 inv cause ledger: fixed ring of recent inventory mutations (no heap).

const std = @import("std");

/// Why an inventory delta happened (conservation / evidence).
pub const Cause = enum(u8) {
    loot = 0,
    craft = 1,
    give = 2,
    place = 3,
    eat = 4,
    drop = 5,
    tx = 6,
    unknown = 7,
};

pub const capacity: usize = 32;

pub const Event = struct {
    peer: u16 = 0,
    item_id: u16 = 0,
    /// Signed delta: positive = gained, negative = lost (magnitude in low bits).
    delta: i16 = 0,
    cause: Cause = .unknown,
};

/// Overwrite ring of the last `capacity` successful inv mutations.
pub const Ledger = struct {
    events: [capacity]Event = [_]Event{.{}} ** capacity,
    /// Next write index (mod capacity).
    head: u8 = 0,
    /// How many slots hold a real event (0..capacity).
    len: u8 = 0,
    /// Lifetime record count (wraps with +%).
    total: u64 = 0,

    pub fn record(self: *Ledger, peer: u16, item_id: u16, delta: i16, cause: Cause) void {
        self.events[self.head] = .{
            .peer = peer,
            .item_id = item_id,
            .delta = delta,
            .cause = cause,
        };
        self.head = @intCast((@as(usize, self.head) + 1) % capacity);
        if (self.len < capacity) self.len += 1;
        self.total +%= 1;
    }

    /// Chronological order: oldest first. Writes up to `out.len` events; returns count.
    pub fn recent(self: *const Ledger, out: []Event) usize {
        const n: usize = @min(out.len, @as(usize, self.len));
        if (n == 0) return 0;
        const start: usize = if (self.len < capacity)
            0
        else
            self.head;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out[i] = self.events[(start + i) % capacity];
        }
        return n;
    }

    pub fn last(self: *const Ledger) ?Event {
        if (self.len == 0) return null;
        const idx: usize = if (self.head == 0) capacity - 1 else @as(usize, self.head) - 1;
        return self.events[idx];
    }
};

test "record and wrap" {
    var led: Ledger = .{};
    var i: u16 = 0;
    while (i < capacity + 5) : (i += 1) {
        led.record(0, i, 1, .give);
    }
    try std.testing.expectEqual(@as(u8, capacity), led.len);
    try std.testing.expectEqual(@as(u64, capacity + 5), led.total);
    const last_ev = led.last().?;
    try std.testing.expectEqual(@as(u16, capacity + 4), last_ev.item_id);
    try std.testing.expectEqual(Cause.give, last_ev.cause);

    var buf: [capacity]Event = undefined;
    const n = led.recent(&buf);
    try std.testing.expectEqual(capacity, n);
    // Oldest kept after wrap: item_id 5 .. capacity+4
    try std.testing.expectEqual(@as(u16, 5), buf[0].item_id);
    try std.testing.expectEqual(@as(u16, capacity + 4), buf[n - 1].item_id);
}

test "empty last and recent" {
    var led: Ledger = .{};
    try std.testing.expect(led.last() == null);
    var buf: [4]Event = undefined;
    try std.testing.expectEqual(@as(usize, 0), led.recent(&buf));
    led.record(1, 7, -2, .drop);
    try std.testing.expectEqual(Cause.drop, led.last().?.cause);
    try std.testing.expectEqual(@as(i16, -2), led.last().?.delta);
}
