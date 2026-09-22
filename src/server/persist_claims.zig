//! Land-claim persistence: claims.zlc save/restore.
//!
//! Split out of server/persist.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("game.zig");
const Game = game_mod.Game;
const max_land_claims = game_mod.max_land_claims;
const io_fs = @import("../util/io_fs.zig");

pub fn saveClaims(self: *Game) !void {
    var path: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "{s}/claims.zlc", .{self.world.world_dir});
    var buf: [max_land_claims * (4 + 4 + 4 + 1 + 32 + 4) + 8]u8 = undefined;
    var o: usize = 0;
    @memcpy(buf[0..4], "ZCLC");
    o = 6; // count patched below
    var count: u16 = 0;
    var i: usize = 0;
    while (i < self.land_claims_n) : (i += 1) {
        const c = &self.land_claims[i];
        if (o + 49 > buf.len) break;
        std.mem.writeInt(i32, buf[o..][0..4], c.x, .little);
        std.mem.writeInt(i32, buf[o + 4 ..][0..4], c.y, .little);
        std.mem.writeInt(i32, buf[o + 8 ..][0..4], c.z, .little);
        buf[o + 12] = c.owner_name_len;
        @memcpy(buf[o + 13 ..][0..32], &c.owner_name);
        std.mem.writeInt(u32, buf[o + 45 ..][0..4], c.owner_seen_day, .little);
        o += 49;
        count += 1;
    }
    std.mem.writeInt(u16, buf[4..6], count, .little);
    try io_fs.writeFile(p, buf[0..o]);
}

/// Restore land claims from claims.zlc. Restored claims have no live owner
/// until their player logs in (reclaimForName re-maps owner_entity); the
/// preserved seen_day keeps the offline expiry math honest. A missing file
/// means fresh world (OpenFailed, like containers.load); any other read
/// failure surfaces so the caller can log before the next save clobbers.
pub fn loadClaims(self: *Game) !void {
    var path: [512]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "{s}/claims.zlc", .{self.world.world_dir});
    const data = io_fs.readFileAll(self.allocator, p) catch |err| switch (err) {
        error.FileNotFound => return error.OpenFailed,
        else => return error.ReadFailed,
    };
    defer self.allocator.free(data);
    if (data.len < 6 or !std.mem.eql(u8, data[0..4], "ZCLC")) return error.BadMagic;
    const count = std.mem.readInt(u16, data[4..6], .little);
    if (count > max_land_claims) return error.BadRecord;
    var claims: @TypeOf(self.land_claims) = undefined;
    var o: usize = 6;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (o + 49 > data.len) return error.Truncated;
        const x = std.mem.readInt(i32, data[o..][0..4], .little);
        const y = std.mem.readInt(i32, data[o + 4 ..][0..4], .little);
        const z = std.mem.readInt(i32, data[o + 8 ..][0..4], .little);
        const name_len = data[o + 12];
        if (name_len > 32) return error.BadRecord;
        var name: [32]u8 = .{0} ** 32;
        @memcpy(name[0..name_len], data[o + 13 ..][0..name_len]);
        const seen = std.mem.readInt(u32, data[o + 45 ..][0..4], .little);
        o += 49;
        claims[i] = .{
            .x = x,
            .y = y,
            .z = z,
            .owner_entity = -1, // re-mapped on login
            .owner_online = false,
            .owner_seen_day = seen,
            .owner_name = name,
            .owner_name_len = name_len,
        };
    }
    @memcpy(self.land_claims[0..count], claims[0..count]);
    self.land_claims_n = count;
}

/// Trader stock persists across restart (traders.zst, magic "ZTR1"): stock
/// `TraderManager` saves its per-trader inventory, so a player's trading
/// window does not re-roll on reboot. Records are keyed by the trader's
/// `TraderStock.name`, entries by item **name** (AssignIds ids are
/// version-dependent), and unknown item names fail closed to a skipped entry.
/// Format: magic | version u8 | count u16 | per trader: name_len u8 + name,
/// reset_interval i32, last_restock_day u32, wallet i32, wallet_default i32,
/// n u8, n x (item_name_len u8 + name, count u16, quality u8, price u16,
/// sell u16, markup i8[, v2: stats_n u8 + stats_n x (effect u8, slot_a i16,
/// slot_b i16)]). v1 files load with no stats.
///
const persist_traders = @import("persist_traders.zig");
pub const ztrScanLen = persist_traders.ztrScanLen;
pub const saveTraders = persist_traders.saveTraders;
pub const loadTraders = persist_traders.loadTraders;
