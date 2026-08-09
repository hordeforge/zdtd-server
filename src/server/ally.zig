//! Ally relationships keyed on PlatformUserIdentifierAbs (stock `AllyStore`).
//!
//! Ally relationships keyed on PlatformUserIdentifierAbs (stock `AllyStore`).
//!
//! Pure state + transition table over identities. No Game import: the caller
//! decodes `NetPackageAllyRequest`, hands both identities here, and broadcasts
//! the returned transition as `NetPackageAllyResponse`. Only the persist
//! helpers (`save`/`load`) touch I/O and take an allocator; the tick path is
//! allocation-free.
//!
//! Grounded in asm.il:
//!   - `AllyStore/AllyStatus` and `AllyStore/AllyEvent` values: 884540, 884550.
//!   - `AllyStore::ComputeTransition`: 885142.
//!   - `AllyStore::GetStatus` / `SetStatus`: 885392 / 885424. SetStatus always
//!     writes both directions, and the reverse direction is the mirror of the
//!     forward one, so one undirected entry per pair is the whole relationship.
//!   - `AllyStore::ProcessAllyRequest`: 885024 (server-only; a null identity on
//!     either side is dropped before anything is written).
//!
//! Persisted to `{world_dir}/allies.zal` (magic ZAL1, zdtd-owned like
//! claims.zlc). Stock keeps allies in PersistentPlayerList; zdtd persists the
//! same relationship set so it survives a server restart.

const std = @import("std");
const platform_user = @import("../wire/platform_user.zig");
const io_fs = @import("../util/io_fs.zig");

pub const Id = platform_user.Id;

/// `AllyStore/AllyStatus` (asm.il 884540), from the source player's side.
pub const Status = enum(u8) {
    not_allied = 0,
    allies = 1,
    outgoing_invite = 2,
    incoming_invite = 3,

    /// The same relationship seen from the other player. `SetStatus` writes this
    /// value into the reverse direction (asm.il 885424).
    pub fn mirror(self: Status) Status {
        return switch (self) {
            .not_allied => .not_allied,
            .allies => .allies,
            .outgoing_invite => .incoming_invite,
            .incoming_invite => .outgoing_invite,
        };
    }
};

/// `AllyStore/AllyEvent` (asm.il 884550). Purely a client-side UI notification.
pub const Event = enum(u8) {
    none = 0,
    outgoing_sent = 1,
    outgoing_canceled = 2,
    incoming_accepted = 3,
    incoming_declined = 4,
    ally_removed = 5,
    outgoing_accepted = 6,
    outgoing_declined = 7,
    incoming_received = 8,
    incoming_canceled = 9,
    removed_by_ally = 10,
};

pub const Transition = struct {
    new_status: Status,
    event_source: Event,
    event_target: Event,

    /// No status change and nothing to tell either side: stock still sends the
    /// response, but there is no reason to put it on the wire.
    pub fn isNoop(self: Transition) bool {
        return self.event_source == .none and self.event_target == .none;
    }
};

/// `AllyStore::ComputeTransition` (asm.il 885142). Defaults are "status
/// unchanged, no events"; only the four listed edges do anything.
pub fn computeTransition(old: Status, add_ally: bool) Transition {
    const unchanged: Transition = .{ .new_status = old, .event_source = .none, .event_target = .none };
    return switch (old) {
        .not_allied => if (add_ally) .{
            .new_status = .outgoing_invite,
            .event_source = .outgoing_sent,
            .event_target = .incoming_received,
        } else unchanged,
        .allies => if (add_ally) unchanged else .{
            .new_status = .not_allied,
            .event_source = .ally_removed,
            .event_target = .removed_by_ally,
        },
        .outgoing_invite => if (add_ally) unchanged else .{
            .new_status = .not_allied,
            .event_source = .outgoing_canceled,
            .event_target = .incoming_canceled,
        },
        .incoming_invite => if (add_ally) .{
            .new_status = .allies,
            .event_source = .incoming_accepted,
            .event_target = .outgoing_accepted,
        } else .{
            .new_status = .not_allied,
            .event_source = .incoming_declined,
            .event_target = .outgoing_declined,
        },
    };
}

/// Relationships tracked at once. Each is a pair, so this covers a full server
/// of mutual allies several times over; beyond it new invites are refused
/// rather than silently evicting someone else's ally.
pub const max_pairs: usize = 256;

const Entry = struct {
    a: platform_user.Stored = .{},
    b: platform_user.Stored = .{},
    /// Status of `a` toward `b`; `b` toward `a` is its mirror.
    status: Status = .not_allied,
    used: bool = false,
};

pub const Store = struct {
    entries: [max_pairs]Entry = [_]Entry{.{}} ** max_pairs,

    /// Index of the entry holding this pair, plus whether it is stored forward
    /// (a=source) or reversed.
    const Hit = struct { index: usize, forward: bool };

    fn find(self: *const Store, source: Id, target: Id) ?Hit {
        for (&self.entries, 0..) |*e, i| {
            if (!e.used) continue;
            if (e.a.matches(source) and e.b.matches(target)) return .{ .index = i, .forward = true };
            if (e.a.matches(target) and e.b.matches(source)) return .{ .index = i, .forward = false };
        }
        return null;
    }

    /// `AllyStore::GetStatus` (asm.il 885392): unknown pairs are NotAllied.
    pub fn status(self: *const Store, source: Id, target: Id) Status {
        const hit = self.find(source, target) orelse return .not_allied;
        const s = self.entries[hit.index].status;
        return if (hit.forward) s else s.mirror();
    }

    pub fn isAlly(self: *const Store, source: Id, target: Id) bool {
        return self.status(source, target) == .allies;
    }

    /// `AllyStore::SetStatus` (asm.il 885424): NotAllied clears the pair,
    /// anything else stores it (mirrored on the reverse direction).
    pub fn setStatus(self: *Store, source: Id, target: Id, new: Status) error{Full}!void {
        if (new == .not_allied) {
            self.clear(source, target);
            return;
        }
        if (self.find(source, target)) |hit| {
            self.entries[hit.index].status = if (hit.forward) new else new.mirror();
            return;
        }
        for (&self.entries) |*e| {
            if (e.used) continue;
            // Overlong ids cannot reach here: they are rejected at the decoder.
            e.a.set(source) catch return error.Full;
            e.b.set(target) catch return error.Full;
            e.status = new;
            e.used = true;
            return;
        }
        return error.Full;
    }

    pub fn clear(self: *Store, source: Id, target: Id) void {
        const hit = self.find(source, target) orelse return;
        self.entries[hit.index] = .{};
    }

    pub fn count(self: *const Store) usize {
        var n: usize = 0;
        for (&self.entries) |*e| {
            if (e.used) n += 1;
        }
        return n;
    }
    /// Persist allies to `{dir}/allies.zal` (magic ZAL1, zdtd-owned like
    /// claims.zlc). Only used pairs are written; identities are len-prefixed.
    /// The encode buffer is heap-owned (max_pairs x ~170 bytes is stack-heavy).
    pub fn save(self: *const Store, dir: []const u8, allocator: std.mem.Allocator) !void {
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/allies.zal", .{dir});
        const buf = try allocator.alloc(u8, 6 + max_pairs * (1 + 16 + 1 + 64 + 1 + 16 + 1 + 64 + 1));
        defer allocator.free(buf);
        @memcpy(buf[0..4], "ZAL1");
        var o: usize = 6; // 4 magic + 2 count reserved; records start at 6
        var save_count: u16 = 0;
        for (&self.entries) |*e| {
            if (!e.used) continue;
            if (o + 170 > buf.len) break;
            buf[o] = e.a.platform_len;
            @memcpy(buf[o + 1 ..][0..e.a.platform_len], e.a.platform_buf[0..e.a.platform_len]);
            o += 1 + e.a.platform_len;
            buf[o] = e.a.id_len;
            @memcpy(buf[o + 1 ..][0..e.a.id_len], e.a.id_buf[0..e.a.id_len]);
            o += 1 + e.a.id_len;
            buf[o] = e.b.platform_len;
            @memcpy(buf[o + 1 ..][0..e.b.platform_len], e.b.platform_buf[0..e.b.platform_len]);
            o += 1 + e.b.platform_len;
            buf[o] = e.b.id_len;
            @memcpy(buf[o + 1 ..][0..e.b.id_len], e.b.id_buf[0..e.b.id_len]);
            o += 1 + e.b.id_len;
            buf[o] = @intFromEnum(e.status);
            o += 1;
            save_count += 1;
        }
        std.mem.writeInt(u16, buf[4..6], save_count, .little);
        try io_fs.writeFile(path, buf[0..o]);
    }

    /// Restore allies from `{dir}/allies.zal`. A missing file is a fresh
    /// server (OpenFailed, like containers.load); any other read failure
    /// surfaces so the caller can log before the next save clobbers data.
    /// Fail closed on corrupt records: overlong identities or a bad status
    /// stop the load at that record.
    pub fn load(self: *Store, dir: []const u8, allocator: std.mem.Allocator) !void {
        var path_buf: [512]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/allies.zal", .{dir});
        const data = io_fs.readFileAll(allocator, path) catch |err| switch (err) {
            error.FileNotFound => return error.OpenFailed,
            else => return error.ReadFailed,
        };
        defer allocator.free(data);
        if (data.len < 6 or !std.mem.eql(u8, data[0..4], "ZAL1")) return error.ReadFailed;
        const load_count = std.mem.readInt(u16, data[4..6], .little);
        var pos: usize = 6;
        var i: u16 = 0;
        while (i < load_count) : (i += 1) {
            const a_plat = readLenStr(data, &pos, 16) orelse return error.ReadFailed;
            const a_id = readLenStr(data, &pos, 64) orelse return error.ReadFailed;
            const b_plat = readLenStr(data, &pos, 16) orelse return error.ReadFailed;
            const b_id = readLenStr(data, &pos, 64) orelse return error.ReadFailed;
            if (pos >= data.len) return error.ReadFailed;
            const st: Status = @enumFromInt(data[pos]);
            pos += 1;
            if (@intFromEnum(st) >= @typeInfo(Status).@"enum".fields.len) return error.ReadFailed;
            self.setStatus(
                .{ .platform = a_plat, .id = a_id },
                .{ .platform = b_plat, .id = b_id },
                st,
            ) catch return error.ReadFailed;
        }
    }

    fn readLenStr(data: []const u8, pos: *usize, max_len: u8) ?[]const u8 {
        if (pos.* >= data.len) return null;
        const len = data[pos.*];
        if (len > max_len) return null;
        pos.* += 1;
        if (pos.* + len > data.len) return null;
        const s = data[pos.* .. pos.* + len];
        pos.* += len;
        return s;
    }

    /// `AllyStore::ProcessAllyRequest` (asm.il 885024): compute the transition
    /// from the current status, apply it, and hand it back so the caller can
    /// send the response. Null-identity guarding happens at the call site,
    /// which is where the decode already knows an identity was absent.
    pub fn processRequest(self: *Store, source: Id, target: Id, add_ally: bool) error{Full}!Transition {
        const t = computeTransition(self.status(source, target), add_ally);
        try self.setStatus(source, target, t.new_status);
        return t;
    }
};

test "transition table matches ComputeTransition" {
    // NotAllied
    try std.testing.expectEqual(Transition{
        .new_status = .outgoing_invite,
        .event_source = .outgoing_sent,
        .event_target = .incoming_received,
    }, computeTransition(.not_allied, true));
    try std.testing.expect(computeTransition(.not_allied, false).isNoop());

    // Allies
    try std.testing.expect(computeTransition(.allies, true).isNoop());
    try std.testing.expectEqual(Transition{
        .new_status = .not_allied,
        .event_source = .ally_removed,
        .event_target = .removed_by_ally,
    }, computeTransition(.allies, false));

    // OutgoingInvite
    try std.testing.expect(computeTransition(.outgoing_invite, true).isNoop());
    try std.testing.expectEqual(Transition{
        .new_status = .not_allied,
        .event_source = .outgoing_canceled,
        .event_target = .incoming_canceled,
    }, computeTransition(.outgoing_invite, false));

    // IncomingInvite
    try std.testing.expectEqual(Transition{
        .new_status = .allies,
        .event_source = .incoming_accepted,
        .event_target = .outgoing_accepted,
    }, computeTransition(.incoming_invite, true));
    try std.testing.expectEqual(Transition{
        .new_status = .not_allied,
        .event_source = .incoming_declined,
        .event_target = .outgoing_declined,
    }, computeTransition(.incoming_invite, false));
}

test "a no-op transition never changes the stored status" {
    var store: Store = .{};
    const a: Id = .{ .platform = "Steam", .id = "1001" };
    const b: Id = .{ .platform = "Steam", .id = "1002" };
    // Declining a relationship that does not exist stays NotAllied and empty.
    const t = try store.processRequest(a, b, false);
    try std.testing.expect(t.isNoop());
    try std.testing.expectEqual(Status.not_allied, store.status(a, b));
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "ally store persists across restart (allies.zal)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    {
        var store: Store = .{};
        try store.setStatus(.{ .platform = "Steam", .id = "1001" }, .{ .platform = "Steam", .id = "1002" }, .allies);
        try store.setStatus(.{ .platform = "EOS", .id = "abc" }, .{ .platform = "Steam", .id = "1001" }, .outgoing_invite);
        try store.save(dir, std.testing.allocator);
    }
    var restored: Store = .{};
    try restored.load(dir, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), restored.count());
    try std.testing.expectEqual(Status.allies, restored.status(
        .{ .platform = "Steam", .id = "1002" },
        .{ .platform = "Steam", .id = "1001" },
    ));
    try std.testing.expectEqual(Status.outgoing_invite, restored.status(
        .{ .platform = "EOS", .id = "abc" },
        .{ .platform = "Steam", .id = "1001" },
    ));
    // Corrupt file fails closed, not silently empty.
    var bad_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bad_path = try std.fmt.bufPrint(&bad_path_buf, "{s}/allies.zal", .{dir});
    try io_fs.writeFile(bad_path, "ZAL1\x00\x01\xff");
    var bad: Store = .{};
    try std.testing.expectError(error.ReadFailed, bad.load(dir, std.testing.allocator));
}

test "invite, accept, remove round-trip from both sides" {
    var store: Store = .{};
    const a: Id = .{ .platform = "Steam", .id = "1001" };
    const b: Id = .{ .platform = "EOS", .id = "beef" };

    _ = try store.processRequest(a, b, true);
    try std.testing.expectEqual(Status.outgoing_invite, store.status(a, b));
    try std.testing.expectEqual(Status.incoming_invite, store.status(b, a));
    try std.testing.expectEqual(@as(usize, 1), store.count());

    // The target accepts: the request comes from b's side this time.
    const acc = try store.processRequest(b, a, true);
    try std.testing.expectEqual(Status.allies, acc.new_status);
    try std.testing.expectEqual(Event.incoming_accepted, acc.event_source);
    try std.testing.expectEqual(Event.outgoing_accepted, acc.event_target);
    try std.testing.expect(store.isAlly(a, b));
    try std.testing.expect(store.isAlly(b, a));
    // Still one pair, not two.
    try std.testing.expectEqual(@as(usize, 1), store.count());

    const rem = try store.processRequest(a, b, false);
    try std.testing.expectEqual(Event.ally_removed, rem.event_source);
    try std.testing.expectEqual(Event.removed_by_ally, rem.event_target);
    try std.testing.expectEqual(Status.not_allied, store.status(a, b));
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "declining an incoming invite clears it for both sides" {
    var store: Store = .{};
    const a: Id = .{ .platform = "Steam", .id = "1001" };
    const b: Id = .{ .platform = "Steam", .id = "1002" };
    _ = try store.processRequest(a, b, true);
    const dec = try store.processRequest(b, a, false);
    try std.testing.expectEqual(Event.incoming_declined, dec.event_source);
    try std.testing.expectEqual(Event.outgoing_declined, dec.event_target);
    try std.testing.expectEqual(Status.not_allied, store.status(a, b));
    try std.testing.expectEqual(Status.not_allied, store.status(b, a));
}

test "same id on different platforms is a different account" {
    var store: Store = .{};
    const steam: Id = .{ .platform = "Steam", .id = "1001" };
    const eos: Id = .{ .platform = "EOS", .id = "1001" };
    const other: Id = .{ .platform = "Steam", .id = "1002" };
    _ = try store.processRequest(steam, other, true);
    try std.testing.expectEqual(Status.outgoing_invite, store.status(steam, other));
    try std.testing.expectEqual(Status.not_allied, store.status(eos, other));
}

test "store is full rather than evicting" {
    var store: Store = .{};
    var id_buf: [max_pairs][8]u8 = undefined;
    var i: usize = 0;
    while (i < max_pairs) : (i += 1) {
        const id = std.fmt.bufPrint(&id_buf[i], "{d}", .{i}) catch unreachable;
        try store.setStatus(.{ .platform = "Steam", .id = id }, .{ .platform = "Steam", .id = "host" }, .allies);
    }
    try std.testing.expectEqual(max_pairs, store.count());
    try std.testing.expectError(error.Full, store.setStatus(
        .{ .platform = "Steam", .id = "overflow" },
        .{ .platform = "Steam", .id = "host" },
        .allies,
    ));
    // An existing pair still updates while the table is full.
    try store.setStatus(.{ .platform = "Steam", .id = "0" }, .{ .platform = "Steam", .id = "host" }, .outgoing_invite);
    try std.testing.expectEqual(Status.outgoing_invite, store.status(
        .{ .platform = "Steam", .id = "0" },
        .{ .platform = "Steam", .id = "host" },
    ));
}

test "clearing a pair frees its slot" {
    var store: Store = .{};
    const a: Id = .{ .platform = "Steam", .id = "1001" };
    const b: Id = .{ .platform = "Steam", .id = "1002" };
    try store.setStatus(a, b, .allies);
    try std.testing.expectEqual(@as(usize, 1), store.count());
    // Clearing from the mirrored direction must find the same entry.
    store.clear(b, a);
    try std.testing.expectEqual(@as(usize, 0), store.count());
    // Clearing an unknown pair is a no-op, not a crash.
    store.clear(a, b);
}
