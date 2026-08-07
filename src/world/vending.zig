//! World-position keyed vending machine tile entities (TileEntityVendingMachine).
//!
//! Domain model only: block Class="VendingMachine" blocks carry a TraderID whose
//! trader_info drives stock, pricing and hours. Ownership / password / rental are
//! stored wire-neutrally (fixed byte buffers) so this module stays free of the
//! wire layer; game.zig converts to platform ids at the send/parse boundary.

const std = @import("std");

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

    pub fn clear(self: *Vending) void {
        self.* = .{};
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
                v.clear();
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
