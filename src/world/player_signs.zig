//! V3.3.0 b18 per-player sign library store (RE gameplay/signs.md §4/§7).
//!
//! Stock persists each player library to `<saveDir>/Player/<libraryId>.signs`
//! (a `SignStoreIO` container of `SignData` v3 blobs). zdtd keeps its own
//! format: one file of `(libraryId, guid, raw SignData blob)` records, because
//! the server relays sign blobs opaquely and never decodes the layer tree
//! (the client owns rendering). The store is what `NetPackageSingleSignData`
//! upserts into and `NetPackageSignDelete` removes from, and it feeds the join
//! `NetPackageSignDataResponse` alongside the prefab catalog so a drawing made
//! in a prior session reaches a later joiner (stock behaviour, signs.md §7).
//!
//! Own format, not stock's: a zdtd player signs file (`ZPS1`), written under
//! the world dir. Bounded: a sign blob is a `LiteNet`-sized packet and a
//! player's library is capped so one peer cannot fill the disk.

const std = @import("std");
const io_fs = @import("../util/io_fs.zig");
const test_tmp = @import("../util/test_tmp.zig");

/// File name under the world dir (zdtd-owned; stock uses `Player/<lib>.signs`).
pub const file_name = "player_signs.zps";

/// Magic + a u16 record count header (`ZPS1`).
const magic = "ZPS1";
const header_len = 4 + 2;

/// Cap on stored player-library signs (zdtd bound; stock's deleted store caps
/// at 10000 but a single server session should not accumulate unbounded blobs).
pub const max_signs: usize = 256;
/// Cap on one `SignData` blob. A `LiteNet` packet body is bounded well under
/// this; a longer push is refused so one peer cannot grow a record without end.
pub const max_blob: usize = 8192;
/// Cap on a player-library id (`<platform>_<id>` combined string).
pub const max_library_id: usize = 192;

/// One stored drawing: the library it belongs to and its opaque `SignData` blob.
pub const PlayerSign = struct {
    library_id: [max_library_id]u8 = undefined,
    library_len: u8 = 0,
    /// The `SignData` blob head carries its 16-byte guid (signs.md §2); the
    /// upsert and delete key on it so a re-draw replaces the same sign.
    guid: [16]u8 = undefined,
    len: u16 = 0,
    blob: [max_blob]u8 = undefined,

    pub fn library(self: *const PlayerSign) []const u8 {
        return self.library_id[0..self.library_len];
    }
};

pub const PlayerSignStore = struct {
    items: [max_signs]PlayerSign = undefined,
    used: [max_signs]bool = @splat(false),
    n: usize = 0,
    cap_warned: bool = false,

    /// Live drawings, for a console row.
    pub fn liveCount(self: *const PlayerSignStore) usize {
        var k: usize = 0;
        for (self.used) |u| {
            if (u) k += 1;
        }
        return k;
    }

    pub fn deinit(self: *PlayerSignStore) void {
        self.* = .{};
    }

    /// Find the stored index for `(library, guid)`, or null.
    fn indexOf(self: *PlayerSignStore, library: []const u8, guid: *const [16]u8) ?usize {
        var seen: usize = 0;
        var i: usize = 0;
        while (i < max_signs and seen < self.n) : (i += 1) {
            if (!self.used[i]) continue;
            seen += 1;
            const e = &self.items[i];
            if (std.mem.eql(u8, e.library(), library) and std.mem.eql(u8, &e.guid, guid)) return i;
        }
        return null;
    }

    /// Insert or replace the sign for `(library, guid)`. Returns null when the
    /// store is full (the push is refused rather than silently dropped).
    pub fn put(self: *PlayerSignStore, library: []const u8, guid: *const [16]u8, blob: []const u8) ?*PlayerSign {
        if (library.len == 0 or library.len > max_library_id) return null;
        if (blob.len == 0 or blob.len > max_blob) return null;
        const existing = self.indexOf(library, guid);
        const idx = existing orelse blk: {
            // Reuse a free slot, else the next free after the last used.
            var i: usize = 0;
            while (i < max_signs) : (i += 1) {
                if (!self.used[i]) {
                    break :blk i;
                }
            }
            return null;
        };
        if (existing == null) {
            if (idx >= max_signs) return null;
            if (idx >= self.n) self.n = idx + 1;
        }
        const e = &self.items[idx];
        self.used[idx] = true;
        @memcpy(e.library_id[0..library.len], library);
        e.library_len = @intCast(library.len);
        @memcpy(&e.guid, guid);
        @memcpy(e.blob[0..blob.len], blob);
        e.len = @intCast(blob.len);
        return e;
    }

    /// Remove the sign for `(library, guid)`; true when it was present.
    pub fn remove(self: *PlayerSignStore, library: []const u8, guid: *const [16]u8) bool {
        const idx = self.indexOf(library, guid) orelse return false;
        self.used[idx] = false;
        // Shrink the live count when this was the last used record.
        while (self.n > 0 and !self.used[self.n - 1]) self.n -= 1;
        return true;
    }

    /// Iterate the live entries in slot order (for the join batch). `cursor`
    /// counts the entries already returned; the end returns null. Repeating
    /// the last entry instead of ending would make a while-until-null caller
    /// spin, which the join filter does.
    pub fn next(self: *PlayerSignStore, cursor: *usize) ?*PlayerSign {
        var seen: usize = 0;
        var i: usize = 0;
        while (i < max_signs and seen < self.n) : (i += 1) {
            if (!self.used[i]) continue;
            if (seen == cursor.*) {
                cursor.* += 1;
                return &self.items[i];
            }
            seen += 1;
        }
        return null;
    }

    /// Write the store to `<dir>/player_signs.zps` (zdtd format, append-only
    /// over a fresh buffer; a full store truncates rather than grows a file
    /// past its bound).
    pub fn save(self: *const PlayerSignStore, dir: []const u8, allocator: std.mem.Allocator) !void {
        var path: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path, "{s}/{s}", .{ dir, file_name });
        const cap = header_len + self.n * (max_library_id + 1 + 16 + 2 + max_blob);
        const buf = try allocator.alloc(u8, cap);
        defer allocator.free(buf);
        @memcpy(buf[0..4], magic);
        var o: usize = header_len;
        var count: u16 = 0;
        var seen: usize = 0;
        var i: usize = 0;
        while (i < max_signs and seen < self.n) : (i += 1) {
            if (!self.used[i]) continue;
            seen += 1;
            const e = &self.items[i];
            if (o + 1 + e.library_len + 16 + 2 + e.len > buf.len) break;
            buf[o] = e.library_len;
            o += 1;
            @memcpy(buf[o..][0..e.library_len], e.library_id[0..e.library_len]);
            o += e.library_len;
            @memcpy(buf[o..][0..16], &e.guid);
            o += 16;
            std.mem.writeInt(u16, buf[o..][0..2], e.len, .little);
            o += 2;
            @memcpy(buf[o..][0..e.len], e.blob[0..e.len]);
            o += e.len;
            count += 1;
        }
        std.mem.writeInt(u16, buf[4..6], count, .little);
        try io_fs.writeFile(p, buf[0..o]);
    }

    pub fn loadFromSlice(self: *PlayerSignStore, buf: []const u8) !void {
        if (buf.len < header_len) return error.InvalidString;
        if (!std.mem.eql(u8, buf[0..4], magic)) return error.InvalidString;
        const count = std.mem.readInt(u16, buf[4..6], .little);
        var o: usize = header_len;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (o + 1 > buf.len) return error.EndOfStream;
            const lib_len = buf[o];
            o += 1;
            if (lib_len > max_library_id or o + lib_len + 16 + 2 > buf.len) return error.EndOfStream;
            const library = buf[o..][0..lib_len];
            o += lib_len;
            var guid: [16]u8 = undefined;
            @memcpy(&guid, buf[o..][0..16]);
            o += 16;
            const blob_len = std.mem.readInt(u16, buf[o..][0..2], .little);
            o += 2;
            if (blob_len > max_blob or o + blob_len > buf.len) return error.EndOfStream;
            _ = self.put(library, &guid, buf[o..][0..blob_len]);
            o += blob_len;
        }
    }

    pub fn load(self: *PlayerSignStore, dir: []const u8) !void {
        var path: [512]u8 = undefined;
        const p = try std.fmt.bufPrint(&path, "{s}/{s}", .{ dir, file_name });
        const data = io_fs.readFileAll(std.heap.page_allocator, p) catch |err| switch (err) {
            error.FileNotFound => return error.OpenFailed,
            else => return error.ReadFailed,
        };
        defer std.heap.page_allocator.free(data);
        return self.loadFromSlice(data);
    }
};

test "player sign store round-trips a blob across save and load" {
    var st: PlayerSignStore = .{};
    defer st.deinit();
    const lib = "Steam_1001";
    var guid: [16]u8 = @splat(0);
    guid[0] = 7;
    const blob = [_]u8{ 3, 0, 0, 0, 9, 1, 2, 3 }; // version=3 head + tail
    try std.testing.expect(st.put(lib, &guid, &blob) != null);
    try std.testing.expectEqual(@as(usize, 1), st.liveCount());

    // A re-draw for the same (library, guid) replaces, not duplicates.
    const blob2 = [_]u8{ 3, 0, 0, 0, 9, 9, 9 };
    try std.testing.expect(st.put(lib, &guid, &blob2) != null);
    try std.testing.expectEqual(@as(usize, 1), st.liveCount());

    // Save to a temp dir, reload into a fresh store, and compare.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try test_tmp.rootOf(&tmp);
    var alloc_impl = std.heap.DebugAllocator(.{}){};
    defer _ = alloc_impl.deinit();
    try st.save(dir, alloc_impl.allocator());

    var st2: PlayerSignStore = .{};
    defer st2.deinit();
    try st2.load(dir);
    try std.testing.expectEqual(@as(usize, 1), st2.liveCount());

    // Delete removes it, and the removal survives a reload.
    try std.testing.expect(st2.remove(lib, &guid));
    try std.testing.expectEqual(@as(usize, 0), st2.liveCount());
    try st2.save(dir, alloc_impl.allocator());
    var st3: PlayerSignStore = .{};
    defer st3.deinit();
    try st3.load(dir);
    try std.testing.expectEqual(@as(usize, 0), st3.liveCount());
}

test "player sign store iterator ends after the last live entry" {
    var st: PlayerSignStore = .{};
    defer st.deinit();
    const blob = [_]u8{1};
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var guid: [16]u8 = @splat(0);
        guid[0] = @truncate(i + 1);
        try std.testing.expect(st.put("lib", &guid, &blob) != null);
    }
    var cursor: usize = 0;
    var seen: usize = 0;
    while (st.next(&cursor)) |_| seen += 1;
    try std.testing.expectEqual(@as(usize, 3), seen);
    try std.testing.expectEqual(@as(usize, 3), cursor);
    // A second pass starts over from the same store, not from the last entry.
    var again: usize = 0;
    cursor = 0;
    while (st.next(&cursor)) |_| again += 1;
    try std.testing.expectEqual(@as(usize, 3), again);
}

test "player sign store bounds reject oversized blobs and full stores" {
    var st: PlayerSignStore = .{};
    defer st.deinit();
    var guid: [16]u8 = @splat(1);
    // An empty or over-cap blob is refused.
    try std.testing.expect(st.put("lib", &guid, &.{}) == null);
    var big: [max_blob + 1]u8 = @splat(0);
    try std.testing.expect(st.put("lib", &guid, &big) == null);
    // An over-long library id is refused.
    var long_lib: [max_library_id + 1]u8 = @splat('a');
    try std.testing.expect(st.put(long_lib[0..], &guid, &.{ 1, 2, 3 }) == null);

    // Fill the store to capacity; the next push returns null.
    const blob = [_]u8{1};
    var i: usize = 0;
    var placed: usize = 0;
    while (i < max_signs + 8) : (i += 1) {
        guid = @splat(0);
        guid[0] = @truncate(i);
        guid[1] = @truncate(i >> 8);
        if (st.put("lib", &guid, &blob)) |_| placed += 1;
    }
    try std.testing.expectEqual(max_signs, placed);
    try std.testing.expectEqual(max_signs, st.liveCount());
}
