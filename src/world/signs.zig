//! Sign text store: the applied composite TileEntity body of a sign block
//! (`TEFeatureSignable`), keyed by world position.
//!
//! Stock keeps a sign's TE in the chunk and ships it with the chunk, so a
//! player who joins later or reloads the area still sees the authored text.
//! The C2S leg echoes a write to everyone in range at edit time, which covers
//! only the session; this store is the copy the chunk stream replays.
//!
//! The body is stored verbatim (handle included, patched to the unsolicited
//! `255` on replay) rather than re-encoded from parsed fields: stock's server
//! applies the client's composite to its own TE and reserializes the same
//! bytes, and `NetPackageTileEntity` is generic, so a second encoder could only
//! drift from the module order the client sent.

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
const containers = @import("containers.zig");

pub const PosKey = containers.PosKey;

/// Body budget per sign. The composite TE body is bounded by the packet
/// (LiteNet MTU) and a sign's text by the client's own input limit, so this is
/// a zdtd bound: a longer body is not stored (the edit still echoes).
pub const max_body: usize = 512;
pub const max_signs: usize = 256;
const persisted_sign_size: usize = 12 + 4 + 2 + max_body; // pos | blockId | len | body
const save_capacity: usize = 6 + max_signs * persisted_sign_size;

pub const Sign = struct {
    pos: PosKey = .{ .x = 0, .y = 0, .z = 0 },
    /// `teBlockId` the client addressed; the chunk-stream replay and the
    /// replace check both key on it.
    block_id: i32 = 0,
    len: u16 = 0,
    body: [max_body]u8 = undefined,
};

pub const SignStore = struct {
    items: [max_signs]Sign = undefined,
    /// Lookup mirror of `items[i].pos` (only valid where `used[i]`); the AoS
    /// copy stays authoritative for save/encode.
    keys: [max_signs]PosKey = .{PosKey{ .x = 0, .y = 0, .z = 0 }} ** max_signs,
    used: [max_signs]bool = .{false} ** max_signs,
    n: usize = 0,
    cap_warned: bool = false,

    pub fn deinit(self: *SignStore) void {
        self.* = .{};
    }

    pub fn get(self: *SignStore, pos: PosKey) ?*Sign {
        var seen: usize = 0;
        var i: usize = 0;
        while (i < max_signs and seen < self.n) : (i += 1) {
            if (!self.used[i]) continue;
            seen += 1;
            if (PosKey.eql(self.keys[i], pos)) return &self.items[i];
        }
        return null;
    }

    /// Store (or replace) the applied body at `pos`. Returns null when the body
    /// is larger than `max_body` or the table is full: the caller still echoes
    /// the edit, it just cannot be replayed later.
    pub fn put(self: *SignStore, pos: PosKey, block_id: i32, body: []const u8) ?*Sign {
        if (body.len > max_body) return null;
        if (self.get(pos)) |s| {
            s.block_id = block_id;
            s.len = @intCast(body.len);
            @memcpy(s.body[0..body.len], body);
            return s;
        }
        var i: usize = 0;
        while (i < max_signs) : (i += 1) {
            if (self.used[i]) continue;
            self.used[i] = true;
            self.keys[i] = pos;
            self.items[i] = .{ .pos = pos, .block_id = block_id, .len = @intCast(body.len) };
            @memcpy(self.items[i].body[0..body.len], body);
            self.n += 1;
            return &self.items[i];
        }
        if (!self.cap_warned) {
            self.cap_warned = true;
            std.debug.print(
                "zdtd: sign table full ({d}); dropping sign text at ({d},{d},{d})\n",
                .{ max_signs, pos.x, pos.y, pos.z },
            );
        }
        return null;
    }

    pub fn remove(self: *SignStore, pos: PosKey) void {
        var i: usize = 0;
        while (i < max_signs) : (i += 1) {
            if (!self.used[i] or !PosKey.eql(self.keys[i], pos)) continue;
            self.used[i] = false;
            self.n -= 1;
            return;
        }
    }

    /// Positions of the stored signs inside one 16x16 chunk column, written to
    /// `out` (bounded by its length). The chunk stream replays them.
    pub fn inChunk(self: *const SignStore, cx: i32, cz: i32, out: []Sign) usize {
        const x0 = cx * 16;
        const z0 = cz * 16;
        var n: usize = 0;
        var seen: usize = 0;
        var i: usize = 0;
        while (i < max_signs and seen < self.n and n < out.len) : (i += 1) {
            if (!self.used[i]) continue;
            seen += 1;
            const s = &self.items[i];
            if (s.pos.x < x0 or s.pos.x >= x0 + 16 or s.pos.z < z0 or s.pos.z >= z0 + 16) continue;
            out[n] = s.*;
            n += 1;
        }
        return n;
    }

    /// ZSG1: magic | count u16 | records (pos 12, blockId i32, len u16, body).
    /// Records are written in slot order; the file is a zdtd-owned format (the
    /// stock save keeps TE data inside the region files).
    pub fn save(self: *const SignStore, dir: []const u8, allocator: std.mem.Allocator) !void {
        var path: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path, "{s}/signs.zsg", .{dir});
        const buf = try allocator.alloc(u8, save_capacity);
        defer allocator.free(buf);
        @memcpy(buf[0..4], "ZSG1");
        var o: usize = 6; // count patched below
        var count: u16 = 0;
        var seen: usize = 0;
        var i: usize = 0;
        while (i < max_signs and seen < self.n) : (i += 1) {
            if (!self.used[i]) continue;
            seen += 1;
            const s = &self.items[i];
            if (o + persisted_sign_size > buf.len) break;
            std.mem.writeInt(i32, buf[o..][0..4], s.pos.x, .little);
            std.mem.writeInt(i32, buf[o + 4 ..][0..4], s.pos.y, .little);
            std.mem.writeInt(i32, buf[o + 8 ..][0..4], s.pos.z, .little);
            std.mem.writeInt(i32, buf[o + 12 ..][0..4], s.block_id, .little);
            std.mem.writeInt(u16, buf[o + 16 ..][0..2], s.len, .little);
            o += 18;
            @memcpy(buf[o..][0..s.len], s.body[0..s.len]);
            o += s.len;
            count += 1;
        }
        std.mem.writeInt(u16, buf[4..6], count, .little);
        try io_fs.writeFile(p, buf[0..o]);
    }

    pub fn loadFromSlice(self: *SignStore, buf: []const u8) !void {
        if (buf.len < 6) return error.InvalidString;
        if (!std.mem.eql(u8, buf[0..4], "ZSG1")) return error.InvalidString;
        const count = std.mem.readInt(u16, buf[4..6], .little);
        var o: usize = 6;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (o + 18 > buf.len) return error.EndOfStream;
            const pos: PosKey = .{
                .x = std.mem.readInt(i32, buf[o..][0..4], .little),
                .y = std.mem.readInt(i32, buf[o + 4 ..][0..4], .little),
                .z = std.mem.readInt(i32, buf[o + 8 ..][0..4], .little),
            };
            const block_id = std.mem.readInt(i32, buf[o + 12 ..][0..4], .little);
            const len = std.mem.readInt(u16, buf[o + 16 ..][0..2], .little);
            o += 18;
            if (len > max_body or o + len > buf.len) return error.EndOfStream;
            _ = self.put(pos, block_id, buf[o..][0..len]);
            o += len;
        }
    }

    pub fn load(self: *SignStore, dir: []const u8) !void {
        var path: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path, "{s}/signs.zsg", .{dir});
        // Only a missing file means "fresh world"; any other read failure must
        // surface so the caller can log it before the next save clobbers data.
        const data = io_fs.readFileAll(std.heap.page_allocator, p) catch |err| switch (err) {
            error.FileNotFound => return error.OpenFailed,
            else => return error.ReadFailed,
        };
        defer std.heap.page_allocator.free(data);
        return self.loadFromSlice(data);
    }
};

test "sign store round-trips a body and lists a chunk slice" {
    var st: SignStore = .{};
    defer st.deinit();
    const body = [_]u8{ 3, 1, 2, 3 };
    try std.testing.expect(st.put(.{ .x = 258, .y = 71, .z = -3 }, 742, &body) != null);
    try std.testing.expect(st.get(.{ .x = 258, .y = 71, .z = -3 }) != null);
    try std.testing.expect(st.get(.{ .x = 1, .y = 1, .z = 1 }) == null);
    // Replace keeps one row and the new body.
    const body2 = [_]u8{ 9, 9 };
    _ = st.put(.{ .x = 258, .y = 71, .z = -3 }, 742, &body2);
    try std.testing.expectEqual(@as(usize, 1), st.n);
    try std.testing.expectEqualSlices(u8, &body2, st.get(.{ .x = 258, .y = 71, .z = -3 }).?.body[0..2]);
    // The chunk slice: (258, -3) is chunk (16, -1), and a sign in another
    // chunk is not listed.
    _ = st.put(.{ .x = 300, .y = 70, .z = 300 }, 742, &body);
    var out: [8]Sign = undefined;
    const got = st.inChunk(16, -1, &out);
    try std.testing.expectEqual(@as(usize, 1), got);
    try std.testing.expectEqual(@as(i32, 258), out[0].pos.x);
    try std.testing.expectEqual(@as(usize, 1), st.inChunk(18, 18, &out));
    // An over-long body is refused rather than truncated.
    var big: [max_body + 1]u8 = undefined;
    @memset(&big, 0);
    try std.testing.expect(st.put(.{ .x = 1, .y = 2, .z = 3 }, 1, &big) == null);
}

test "sign store save and load round-trip" {
    var st: SignStore = .{};
    defer st.deinit();
    const body = [_]u8{ 1, 2, 3, 4, 5 };
    _ = st.put(.{ .x = -5, .y = 71, .z = 9 }, 900, &body);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(std.testing.io, &dir_buf)];
    try st.save(dir, std.testing.allocator);
    var st2: SignStore = .{};
    defer st2.deinit();
    try st2.load(dir);
    const s = st2.get(.{ .x = -5, .y = 71, .z = 9 }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 900), s.block_id);
    try std.testing.expectEqualSlices(u8, &body, s.body[0..s.len]);
}
