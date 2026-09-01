//! World-position keyed vending machine tile entities (TileEntityVendingMachine).
//!
//! Domain model only: block Class="VendingMachine" blocks carry a TraderID whose
//! trader_info drives stock, pricing and hours. Ownership / password / rental are
//! stored wire-neutrally (fixed byte buffers) so this module stays free of the
//! wire layer; game.zig converts to platform ids at the send/parse boundary.

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");

pub const max_vending: usize = 128;
/// Stock rows (TraderData.Entry); trader_info lists are far smaller.
pub const max_vending_stock: usize = 48;
pub const max_allowed_users: usize = 8;
pub const max_password_hash: usize = 64;

pub const PosKey = struct {
    x: i32,
    y: i32,
    z: i32,

    pub fn eql(a: PosKey, b: PosKey) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z;
    }
};

/// One TraderData.Entry row (wire-ready: ItemStack + markup i8).
pub const StockEntry = struct {
    type_id: i32 = 0,
    count: i32 = 1,
    quality: u8 = 1,
    markup: i8 = 0,
};

pub const UserRef = struct {
    platform: [max_platform_len]u8 = .{0} ** max_platform_len,
    platform_len: u8 = 0,
    id: [max_id_len]u8 = .{0} ** max_id_len,
    id_len: u8 = 0,

    /// Copy an identity in (rent sets the owner). Overlong strings are
    /// rejected: truncating an id would merge two accounts onto one machine.
    pub fn set(self: *UserRef, v: anytype) error{Overflow}!void {
        if (v.platform.len > max_platform_len or v.id.len > max_id_len) return error.Overflow;
        @memcpy(self.platform[0..v.platform.len], v.platform);
        @memcpy(self.id[0..v.id.len], v.id);
        self.platform_len = @intCast(v.platform.len);
        self.id_len = @intCast(v.id.len);
    }

    /// True when the stored owner equals `v` (or when both are absent).
    pub fn matches(self: *const UserRef, v: anytype) bool {
        if (self.platform_len == 0) return false;
        if (v.platform.len != self.platform_len or v.id.len != self.id_len) return false;
        return std.mem.eql(u8, self.platform[0..self.platform_len], v.platform) and
            std.mem.eql(u8, self.id[0..self.id_len], v.id);
    }
};

/// TE payload fields shared with the wire writer, buffer-sized for sim.
pub const max_platform_len = 16;
pub const max_id_len = 64;

pub const Vending = struct {
    pos: PosKey = .{ .x = 0, .y = 0, .z = 0 },
    block_id: i32 = 0,
    /// TraderID from blocks.xml (TraderData.TraderID; resolves trader_info).
    trader_id: i32 = 0,
    available_money: i32 = 0,
    stock: [max_vending_stock]StockEntry = [_]StockEntry{.{}} ** max_vending_stock,
    stock_n: u8 = 0,
    is_locked: bool = false,
    owner: UserRef = .{},
    password_hash: [max_password_hash]u8 = .{0} ** max_password_hash,
    password_len: u8 = 0,
    allowed: [max_allowed_users]UserRef = [_]UserRef{.{}} ** max_allowed_users,
    allowed_n: u8 = 0,
    /// In-game day the rental expires (0 = not rented; ClearVendingMachine on
    /// currentDay > rental_end_day).
    rental_end_day: i32 = 0,
    /// trader_info Rentable drives the optional nextAutoBuy u64 on the wire.
    rentable: bool = false,
    next_auto_buy: u64 = 0,

    /// ClearVendingMachine / ClearOwner (loot-economy §6): the machine returns
    /// to Unowned. The block identity (pos / block_id / trader_id) and the
    /// stocked entries survive; only ownership, access and the rental term go.
    pub fn clear(self: *Vending) void {
        const pos = self.pos;
        const block_id = self.block_id;
        const trader_id = self.trader_id;
        const stock = self.stock;
        const stock_n = self.stock_n;
        self.* = .{};
        self.pos = pos;
        self.block_id = block_id;
        self.trader_id = trader_id;
        self.stock = stock;
        self.stock_n = stock_n;
    }
};

/// Fixed-cap array store, embedded in Game (no heap on the tick path).
pub const VendingStore = struct {
    items: [max_vending]Vending = [_]Vending{.{}} ** max_vending,
    used: [max_vending]bool = [_]bool{false} ** max_vending,

    pub fn count(self: *const VendingStore) usize {
        var n: usize = 0;
        for (self.used) |u| {
            if (u) n += 1;
        }
        return n;
    }

    pub fn get(self: *VendingStore, pos: PosKey) ?*Vending {
        for (&self.items, 0..) |*v, i| {
            if (self.used[i] and v.pos.eql(pos)) return v;
        }
        return null;
    }

    /// First free slot or null at cap (fail closed: no grow).
    pub fn getOrCreate(self: *VendingStore, pos: PosKey, block_id: i32, trader_id: i32) ?*Vending {
        if (self.get(pos)) |v| return v;
        for (&self.items, 0..) |*v, i| {
            if (!self.used[i]) {
                // Full reset: a freed slot may carry a previous machine's
                // stock/ownership at a different position (clear() only
                // wipes ownership for the ClearVendingMachine in-place op).
                v.* = .{};
                v.pos = pos;
                v.block_id = block_id;
                v.trader_id = trader_id;
                self.used[i] = true;
                return v;
            }
        }
        return null;
    }

    pub fn removeAt(self: *VendingStore, pos: PosKey) void {
        for (&self.items, 0..) |*v, i| {
            if (self.used[i] and v.pos.eql(pos)) {
                v.clear();
                self.used[i] = false;
                return;
            }
        }
    }

    // --- Persistence (vending.zvn, "ZVNM1") ---
    //
    // World-owned vending machines must survive a restart (AGENTS rule 21): a
    // placed machine that lost its store would silently stop opening. Format is
    // containers.zct-shaped: magic | count | records, each record carrying the
    // full TraderData-ish state (stock rows, ownership, password, rental).

    const magic = "ZVNM";
    /// Worst-case per-record size: pos/block/trader/money (24) + stock_n (1) +
    /// stock rows (48*10) + is_locked (1) + owner UserRef (82) + password_len
    /// (1) + password hash (64) + allowed_n (1) + allowed UserRefs (8*82) +
    /// rental_end_day/rentable/next_auto_buy (13) = 1323 bytes.
    const max_record_bytes: usize = 24 + 1 + max_vending_stock * 10 + 1 + 82 + 1 + max_password_hash + 1 + max_allowed_users * 82 + 13;
    const save_capacity: usize = max_vending * max_record_bytes;

    fn writeUserRef(buf: []u8, o: *usize, u: UserRef) bool {
        if (o.* + 1 + max_platform_len + 1 + max_id_len > buf.len) return false;
        buf[o.*] = u.platform_len;
        o.* += 1;
        @memcpy(buf[o.*..][0..max_platform_len], &u.platform);
        o.* += max_platform_len;
        buf[o.*] = u.id_len;
        o.* += 1;
        @memcpy(buf[o.*..][0..max_id_len], &u.id);
        o.* += max_id_len;
        return true;
    }

    fn readUserRef(buf: []const u8, o: *usize, u: *UserRef) bool {
        if (o.* + 1 + max_platform_len + 1 + max_id_len > buf.len) return false;
        u.platform_len = buf[o.*];
        o.* += 1;
        @memcpy(&u.platform, buf[o.*..][0..max_platform_len]);
        o.* += max_platform_len;
        u.id_len = buf[o.*];
        o.* += 1;
        @memcpy(&u.id, buf[o.*..][0..max_id_len]);
        o.* += max_id_len;
        // The wire send path slices these fixed buffers by the declared lengths
        // (game.zig vendingOwnerId); a corrupt save claiming more than the
        // stored bytes must fail closed, not pass a bad UserRef on.
        return u.platform_len <= max_platform_len and u.id_len <= max_id_len;
    }

    pub fn save(self: *const VendingStore, dir: []const u8) !void {
        var path: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path, "{s}/vending.zvn", .{dir});
        var buf: [save_capacity]u8 = undefined;
        var o: usize = 0;
        @memcpy(buf[0..4], magic);
        o = 6; // count patched below

        var saved_count: u16 = 0;
        var vi: usize = 0;
        while (vi < max_vending) : (vi += 1) {
            if (!self.used[vi]) continue;
            const v = &self.items[vi];
            if (o + 12 + 4 + 4 + 4 + 1 + @as(usize, v.stock_n) * 10 + 1 + 82 + 1 + max_password_hash + 1 + @as(usize, v.allowed_n) * 82 + 4 + 1 + 8 > buf.len) break;
            std.mem.writeInt(i32, buf[o..][0..4], v.pos.x, .little);
            std.mem.writeInt(i32, buf[o + 4 ..][0..4], v.pos.y, .little);
            std.mem.writeInt(i32, buf[o + 8 ..][0..4], v.pos.z, .little);
            std.mem.writeInt(i32, buf[o + 12 ..][0..4], v.block_id, .little);
            std.mem.writeInt(i32, buf[o + 16 ..][0..4], v.trader_id, .little);
            std.mem.writeInt(i32, buf[o + 20 ..][0..4], v.available_money, .little);
            o += 24;
            buf[o] = v.stock_n;
            o += 1;
            var s: usize = 0;
            while (s < v.stock_n) : (s += 1) {
                const e = v.stock[s];
                std.mem.writeInt(i32, buf[o..][0..4], e.type_id, .little);
                std.mem.writeInt(i32, buf[o + 4 ..][0..4], e.count, .little);
                buf[o + 8] = e.quality;
                buf[o + 9] = @bitCast(e.markup);
                o += 10;
            }
            buf[o] = @intFromBool(v.is_locked);
            o += 1;
            if (!writeUserRef(buf[0..], &o, v.owner)) break;
            buf[o] = v.password_len;
            o += 1;
            @memcpy(buf[o..][0..max_password_hash], &v.password_hash);
            o += max_password_hash;
            buf[o] = v.allowed_n;
            o += 1;
            var ai: usize = 0;
            while (ai < v.allowed_n) : (ai += 1) {
                if (!writeUserRef(buf[0..], &o, v.allowed[ai])) break;
            }
            std.mem.writeInt(i32, buf[o..][0..4], v.rental_end_day, .little);
            buf[o + 4] = @intFromBool(v.rentable);
            std.mem.writeInt(u64, buf[o + 5 ..][0..8], v.next_auto_buy, .little);
            o += 13;
            saved_count += 1;
        }
        std.mem.writeInt(u16, buf[4..6], saved_count, .little);
        try io_fs.writeFile(p, buf[0..o]);
    }

    /// Decode a ZVNM1 buffer (magic | count | records). Used by load and fuzz.
    pub fn loadFromSlice(self: *VendingStore, buf: []const u8) !void {
        const len = buf.len;
        if (len < 6 or !std.mem.eql(u8, buf[0..4], magic)) return error.ReadFailed;
        const n_records = std.mem.readInt(u16, buf[4..6], .little);
        var o: usize = 6;
        var vi: u16 = 0;
        while (vi < n_records) : (vi += 1) {
            if (o + 24 + 1 > len) return error.ReadFailed;
            const pos: PosKey = .{
                .x = std.mem.readInt(i32, buf[o..][0..4], .little),
                .y = std.mem.readInt(i32, buf[o + 4 ..][0..4], .little),
                .z = std.mem.readInt(i32, buf[o + 8 ..][0..4], .little),
            };
            const block_id = std.mem.readInt(i32, buf[o + 12 ..][0..4], .little);
            const trader_id = std.mem.readInt(i32, buf[o + 16 ..][0..4], .little);
            const money = std.mem.readInt(i32, buf[o + 20 ..][0..4], .little);
            const stock_n = buf[o + 24];
            o += 25;
            if (o + @as(usize, stock_n) * 10 > len) return error.ReadFailed;
            // A record can be dropped (table full), but every one of its bytes
            // still has to be consumed: the stock rows AND the lock/owner/
            // password/allowed/rental tail below. Skipping only the stock left
            // the cursor mid-record and shifted every following machine.
            const maybe_v = self.getOrCreate(pos, block_id, trader_id);
            if (maybe_v) |v| v.available_money = money;
            var s: usize = 0;
            while (s < stock_n) : (s += 1) {
                if (maybe_v) |v| {
                    if (s < max_vending_stock) {
                        v.stock[s] = .{
                            .type_id = std.mem.readInt(i32, buf[o..][0..4], .little),
                            .count = std.mem.readInt(i32, buf[o + 4 ..][0..4], .little),
                            .quality = buf[o + 8],
                            .markup = @bitCast(buf[o + 9]),
                        };
                    }
                }
                o += 10;
            }
            if (maybe_v) |v| v.stock_n = @min(stock_n, max_vending_stock);
            if (o + 1 > len) return error.ReadFailed;
            if (maybe_v) |v| v.is_locked = buf[o] != 0;
            o += 1;
            var owner_sink: UserRef = .{};
            if (!readUserRef(buf, &o, if (maybe_v) |v| &v.owner else &owner_sink)) return error.ReadFailed;
            if (o + 1 + max_password_hash > len) return error.ReadFailed;
            const raw_password_len = buf[o];
            // Same fail-closed rule as UserRef: password_len must fit the
            // fixed hash buffer the wire path slices (game.zig password_hash).
            if (raw_password_len > max_password_hash) return error.ReadFailed;
            o += 1;
            if (maybe_v) |v| {
                v.password_len = raw_password_len;
                @memcpy(&v.password_hash, buf[o..][0..max_password_hash]);
            }
            o += max_password_hash;
            if (o + 1 > len) return error.ReadFailed;
            // Same clamp rule as stock_n: the raw on-disk count drives how many
            // records are read off the wire (o must land past all of them), but
            // the stored count must never exceed the fixed array.
            const raw_allowed_n = buf[o];
            if (maybe_v) |v| v.allowed_n = @min(raw_allowed_n, max_allowed_users);
            o += 1;
            var ai: usize = 0;
            while (ai < raw_allowed_n) : (ai += 1) {
                var tmp: UserRef = .{};
                const dst = if (maybe_v) |v| (if (ai < max_allowed_users) &v.allowed[ai] else &tmp) else &tmp;
                if (!readUserRef(buf, &o, dst)) return error.ReadFailed;
            }
            if (o + 13 > len) return error.ReadFailed;
            if (maybe_v) |v| {
                v.rental_end_day = std.mem.readInt(i32, buf[o..][0..4], .little);
                v.rentable = buf[o + 4] != 0;
                v.next_auto_buy = std.mem.readInt(u64, buf[o + 5 ..][0..8], .little);
            }
            o += 13;
        }
    }

    pub fn load(self: *VendingStore, dir: []const u8) !void {
        var path: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path, "{s}/vending.zvn", .{dir});
        var buf: [save_capacity]u8 = undefined;
        const bytes = io_fs.readFileInto(p, &buf) catch |err| switch (err) {
            // No file = never saved; caller regenerates. Anything else surfaces
            // so the caller logs it before the next save clobbers data.
            error.FileNotFound => return error.OpenFailed,
            else => |e| return e,
        };
        try self.loadFromSlice(bytes);
    }
};

test "vending store keys by position and caps at max_vending" {
    var st: VendingStore = .{};
    const a = st.getOrCreate(.{ .x = 1, .y = 2, .z = 3 }, 100, 4).?;
    try std.testing.expectEqual(@as(i32, 4), a.trader_id);
    try std.testing.expectEqual(@as(i32, 100), a.block_id);
    // Same pos returns the same slot.
    try std.testing.expectEqual(@as(*Vending, a), st.getOrCreate(.{ .x = 1, .y = 2, .z = 3 }, 100, 4));
    // Removal frees the slot.
    st.removeAt(.{ .x = 1, .y = 2, .z = 3 });
    try std.testing.expect(st.get(.{ .x = 1, .y = 2, .z = 3 }) == null);
    const b = st.getOrCreate(.{ .x = 9, .y = 0, .z = 0 }, 200, 10).?;
    try std.testing.expectEqual(@as(i32, 10), b.trader_id);
}

test "vending store round-trips through the ZVNM1 save format" {
    var st: VendingStore = .{};
    const a = st.getOrCreate(.{ .x = 1, .y = 2, .z = 3 }, 100, 4).?;
    a.available_money = 1234;
    a.stock_n = 2;
    a.stock[0] = .{ .type_id = 65537, .count = 5, .quality = 3, .markup = 0 };
    a.stock[1] = .{ .type_id = 65538, .count = 1, .quality = 1, .markup = 2 };
    a.is_locked = true;
    a.owner.platform_len = 4;
    @memcpy(a.owner.platform[0..4], "test");
    a.owner.id_len = 6;
    @memcpy(a.owner.id[0..6], "user42");
    a.password_len = 4;
    @memcpy(a.password_hash[0..4], "h4sh");
    a.allowed_n = 1;
    a.allowed[0].id_len = 3;
    @memcpy(a.allowed[0].id[0..3], "bob");
    a.rental_end_day = 17;
    a.rentable = true;
    a.next_auto_buy = 9876543210;
    _ = st.getOrCreate(.{ .x = 9, .y = 0, .z = 0 }, 200, 10);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    try st.save(dir);

    var st2: VendingStore = .{};
    try st2.load(dir);
    try std.testing.expectEqual(@as(usize, 2), st2.count());
    const a2 = st2.get(.{ .x = 1, .y = 2, .z = 3 }).?;
    try std.testing.expectEqual(@as(i32, 1234), a2.available_money);
    try std.testing.expectEqual(@as(u8, 2), a2.stock_n);
    try std.testing.expectEqual(@as(i32, 65537), a2.stock[0].type_id);
    try std.testing.expectEqual(@as(i32, 5), a2.stock[0].count);
    try std.testing.expectEqual(@as(u8, 3), a2.stock[0].quality);
    try std.testing.expect(a2.is_locked);
    try std.testing.expectEqual(@as(u8, 4), a2.owner.platform_len);
    try std.testing.expectEqualStrings("user42", a2.owner.id[0..a2.owner.id_len]);
    try std.testing.expectEqual(@as(u8, 4), a2.password_len);
    try std.testing.expectEqual(@as(u8, 1), a2.allowed_n);
    try std.testing.expectEqualStrings("bob", a2.allowed[0].id[0..a2.allowed[0].id_len]);
    try std.testing.expectEqual(@as(i32, 17), a2.rental_end_day);
    try std.testing.expect(a2.rentable);
    try std.testing.expectEqual(@as(u64, 9876543210), a2.next_auto_buy);
    const b2 = st2.get(.{ .x = 9, .y = 0, .z = 0 }).?;
    try std.testing.expectEqual(@as(i32, 10), b2.trader_id);
}

test "a dropped ZVNM record does not desync the records after it" {
    // getOrCreate returns null once the table holds max_vending machines. The
    // loader must consume that record whole: the stock rows AND the lock,
    // owner, password, allowed-user and rental tail. Skipping only the stock
    // left the cursor mid-record and shifted every following machine.
    var src: VendingStore = .{};
    // First record gets a full tail so the skipped span is large and
    // distinctive; the second carries values the assertions below pin.
    const drop = src.getOrCreate(.{ .x = 1000, .y = 0, .z = 0 }, 1, 1).?;
    drop.stock_n = 2;
    drop.stock[0] = .{ .type_id = 111, .count = 9, .quality = 1, .markup = 0 };
    drop.is_locked = true;
    drop.owner.id_len = 5;
    @memcpy(drop.owner.id[0..5], "gonzo");
    drop.password_len = 3;
    @memcpy(drop.password_hash[0..3], "abc");
    drop.allowed_n = 2;
    drop.rental_end_day = 42;
    const keep = src.getOrCreate(.{ .x = 2000, .y = 0, .z = 0 }, 2, 7).?;
    keep.available_money = 555;
    keep.stock_n = 1;
    keep.stock[0] = .{ .type_id = 222, .count = 4, .quality = 2, .markup = 1 };
    keep.rental_end_day = 17;
    keep.next_auto_buy = 99;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    try src.save(dir);

    // Load into a store that is full EXCEPT that the second record's position
    // is already present: the first record on disk is dropped, and the second
    // must still be parsed at the right offset and applied to that machine.
    var dst: VendingStore = .{};
    _ = dst.getOrCreate(.{ .x = 2000, .y = 0, .z = 0 }, 2, 7).?;
    var i: usize = 0;
    while (dst.count() < max_vending) : (i += 1) {
        _ = dst.getOrCreate(.{ .x = @intCast(i), .y = 0, .z = 0 }, 1, 1) orelse break;
    }
    try std.testing.expectEqual(max_vending, dst.count());
    try std.testing.expect(dst.getOrCreate(.{ .x = 1000, .y = 0, .z = 0 }, 1, 1) == null);

    try dst.load(dir);
    // The kept record was read from the correct offset, not shifted by the
    // dropped record's lock/owner/password/allowed/rental tail.
    const k = dst.get(.{ .x = 2000, .y = 0, .z = 0 }).?;
    try std.testing.expectEqual(@as(i32, 555), k.available_money);
    try std.testing.expectEqual(@as(u8, 1), k.stock_n);
    try std.testing.expectEqual(@as(i32, 222), k.stock[0].type_id);
    try std.testing.expectEqual(@as(i32, 4), k.stock[0].count);
    try std.testing.expectEqual(@as(i32, 17), k.rental_end_day);
    try std.testing.expectEqual(@as(u64, 99), k.next_auto_buy);
}
