//! Stock `NameIdMapping` blob (the `data` payload of NetPackageIdMapping).
//!
//! Layout, from `NameIdMapping::SaveToWriter` (asm.il 1178353-1178450) and the
//! reader that has to accept it, `NameIdMapping::LoadFromReader`
//! (asm.il 1178631-1178717):
//!
//!     i32 version (written as 1, the reader pops it)
//!     i32 count
//!     count x ( i32 id | 7-bit-length UTF-8 string )
//!
//! Writing this is all-or-nothing on purpose. `NameIdMapping::LoadFromArray`
//! swallows every exception and returns false (asm.il 1178553-1178629) while
//! leaving `Block.nameIdMapping` non-null, so a truncated or out-of-range blob
//! does not disable the mapping: `Block::AssignIds` still takes the mapping
//! branch (asm.il 101408-101432), and `assignIdsFromMapping` +
//! `assignLeftOverBlocks` (asm.il 101288-101356, 101135-101286) then renumber
//! every block the blob failed to name, silently and with no client-side error.

const std = @import("std");

/// `Block::MAX_BLOCKS` (asm.il 102624-102627). The client's `idsToNames` array
/// is exactly this long, so `idsToNames[id] = name` throws for anything larger.
pub const max_blocks: u32 = 0x10000;

/// Fixed prefix: version + count.
pub const header_len: usize = 8;

pub const Error = error{
    /// id >= Block.MAX_BLOCKS: `stelem.ref` would throw inside LoadFromReader.
    IdOutOfRange,
    /// Empty names cannot be looked up by `GetIdForName`, so the block they
    /// stand for would fall through to assignLeftOverBlocks anyway.
    EmptyName,
    /// Two names claiming one id: the client's `idsToNames` slot keeps whichever
    /// arrives last, so the other block silently loses its negotiated id.
    DuplicateId,
    /// .NET BinaryWriter.Write(string) prefixes a 7-bit length; nothing in the
    /// stock dump is anywhere near this, so a longer name means a corrupt source.
    NameTooLong,
    /// The row count written in the header does not match the rows emitted. The
    /// client would read past the last name into whatever follows.
    CountMismatch,
};

/// Longest block name we will serialize. Stock's longest is well under 64.
pub const max_name_len: usize = 255;

pub const Summary = struct {
    count: u32,
    /// Total blob bytes, header included.
    bytes: usize,
};

/// Bitset of claimed ids, one bit per possible block id.
const SeenSet = [max_blocks / 8]u8;

/// Bytes `.NET` BinaryWriter.Write(string) emits for `name`.
fn stringLen(name: []const u8) usize {
    return len7Bit(@intCast(name.len)) + name.len;
}

fn len7Bit(value: u32) usize {
    var v = value;
    var n: usize = 1;
    while (v >= 0x80) : (v >>= 7) n += 1;
    return n;
}

fn write7Bit(w: *std.Io.Writer, value: u32) std.Io.Writer.Error!void {
    var v = value;
    while (v >= 0x80) : (v >>= 7) {
        try w.writeByte(@truncate((v & 0x7f) | 0x80));
    }
    try w.writeByte(@truncate(v));
}

/// Validate every row and measure the blob. `it` yields `?struct { id, name }`
/// (any iterator shape with a `next` method works); it is consumed.
///
/// `seen` is caller-owned scratch so this stays allocation-free on a 64 KiB
/// bitset that has no business on a call stack.
pub fn measure(it: anytype, seen: *SeenSet) Error!Summary {
    @memset(seen, 0);
    var s: Summary = .{ .count = 0, .bytes = header_len };
    var iter = it;
    while (iter.next()) |e| {
        if (e.name.len == 0) return Error.EmptyName;
        if (e.name.len > max_name_len) return Error.NameTooLong;
        const id: u32 = e.id;
        if (id >= max_blocks) return Error.IdOutOfRange;
        const bit: u8 = @as(u8, 1) << @intCast(id % 8);
        if (seen[id / 8] & bit != 0) return Error.DuplicateId;
        seen[id / 8] |= bit;
        s.count += 1;
        s.bytes += 4 + stringLen(e.name);
    }
    return s;
}

/// Serialize the blob. `summary` must come from `measure` over an identical
/// iteration, so the count written up front matches the rows that follow.
pub fn write(w: *std.Io.Writer, it: anytype, summary: Summary) (Error || std.Io.Writer.Error)!void {
    try w.writeInt(i32, 1, .little); // version; the reader discards it
    try w.writeInt(i32, @intCast(summary.count), .little);
    var written: u32 = 0;
    var iter = it;
    while (iter.next()) |e| {
        if (written == summary.count) return Error.CountMismatch;
        if (e.name.len == 0 or e.name.len > max_name_len) return Error.EmptyName;
        if (@as(u32, e.id) >= max_blocks) return Error.IdOutOfRange;
        try w.writeInt(i32, e.id, .little);
        try write7Bit(w, @intCast(e.name.len));
        try w.writeAll(e.name);
        written += 1;
    }
    // A short body would leave the client reading past the blob into nothing.
    if (written != summary.count) return Error.CountMismatch;
}

/// Iterator over a fixed slice; the shape `measure`/`write` expect.
pub fn sliceIter(entries: []const Entry) SliceIter {
    return .{ .entries = entries };
}

pub const Entry = struct { id: u16, name: []const u8 };

pub const SliceIter = struct {
    entries: []const Entry,
    i: usize = 0,

    pub fn next(self: *SliceIter) ?Entry {
        if (self.i >= self.entries.len) return null;
        defer self.i += 1;
        return self.entries[self.i];
    }
};

test "two entry mapping is byte exact" {
    const entries = [_]Entry{
        .{ .id = 1, .name = "terrStone" },
        .{ .id = 24629, .name = "treeOakSml01" },
    };
    var seen: SeenSet = undefined;
    const s = try measure(sliceIter(&entries), &seen);
    try std.testing.expectEqual(@as(u32, 2), s.count);
    try std.testing.expectEqual(@as(usize, 8 + 4 + 1 + 9 + 4 + 1 + 12), s.bytes);

    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, sliceIter(&entries), s);
    const out = buf[0..w.end];
    try std.testing.expectEqual(s.bytes, out.len);
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, out[0..4], .little));
    try std.testing.expectEqual(@as(i32, 2), std.mem.readInt(i32, out[4..8], .little));
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, out[8..12], .little));
    try std.testing.expectEqual(@as(u8, 9), out[12]);
    try std.testing.expectEqualStrings("terrStone", out[13..22]);
    try std.testing.expectEqual(@as(i32, 24629), std.mem.readInt(i32, out[22..26], .little));
    try std.testing.expectEqual(@as(u8, 12), out[26]);
    try std.testing.expectEqualStrings("treeOakSml01", out[27..39]);
}

test "empty mapping is header only" {
    var seen: SeenSet = undefined;
    const s = try measure(sliceIter(&.{}), &seen);
    try std.testing.expectEqual(@as(u32, 0), s.count);
    try std.testing.expectEqual(header_len, s.bytes);
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, sliceIter(&.{}), s);
    try std.testing.expectEqual(header_len, w.end);
}

test "measure rejects rows the client cannot load" {
    var seen: SeenSet = undefined;
    const empty_name = [_]Entry{.{ .id = 3, .name = "" }};
    try std.testing.expectError(Error.EmptyName, measure(sliceIter(&empty_name), &seen));

    const dup = [_]Entry{ .{ .id = 7, .name = "a" }, .{ .id = 7, .name = "b" } };
    try std.testing.expectError(Error.DuplicateId, measure(sliceIter(&dup), &seen));

    // u16 ids cannot exceed MAX_BLOCKS-1, so the range guard is exercised through
    // the widened check the writer performs on every row.
    try std.testing.expectEqual(@as(u32, 0x10000), max_blocks);
    const top = [_]Entry{.{ .id = 0xffff, .name = "last" }};
    try std.testing.expectEqual(@as(u32, 1), (try measure(sliceIter(&top), &seen)).count);
}

test "write refuses to emit fewer rows than the header promises" {
    const entries = [_]Entry{.{ .id = 1, .name = "a" }};
    var seen: SeenSet = undefined;
    var s = try measure(sliceIter(&entries), &seen);
    s.count = 2; // header claims a row the iterator does not have
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(Error.CountMismatch, write(&w, sliceIter(&entries), s));
}

test "bundled AssignIds dump is a complete, in-range mapping source" {
    const maxdamage = @import("../assets/maxdamage.zig");
    var t = maxdamage.Table.empty();
    defer t.deinit();
    t.tryMergeBundledAssignIds(std.testing.allocator);
    if (t.idNameCount() == 0) return error.SkipZigTest;

    const seen = try std.testing.allocator.create(SeenSet);
    defer std.testing.allocator.destroy(seen);
    const s = try measure(t.idNameIterator(), seen);
    try std.testing.expectEqual(t.idNameCount(), s.count);
    try std.testing.expect(s.count > 24000);
    // The blob is far past the 512 KiB body buffer, which is exactly why the
    // sender streams it into the deflate framer instead of building it first.
    try std.testing.expect(s.bytes > 512 * 1024);
}

test "full blocks mapping frames inside the server body buffer" {
    const maxdamage = @import("../assets/maxdamage.zig");
    const frame = @import("frame.zig");
    var t = maxdamage.Table.empty();
    defer t.deinit();
    t.tryMergeBundledAssignIds(std.testing.allocator);
    if (t.idNameCount() == 0) return error.SkipZigTest;

    const seen = try std.testing.allocator.create(SeenSet);
    defer std.testing.allocator.destroy(seen);
    const s = try measure(t.idNameIterator(), seen);

    // Game.body_buf and the deflate window, both too large for a test stack.
    const send_buf = try std.testing.allocator.alloc(u8, 524288);
    defer std.testing.allocator.free(send_buf);
    const window = try std.testing.allocator.alloc(u8, frame.DeflateFramer.window_len);
    defer std.testing.allocator.free(window);

    const map_name = "blocks";
    const body_len = 1 + map_name.len + 4 + s.bytes;
    var fr: frame.DeflateFramer = undefined;
    try fr.begin(send_buf, window, 0, 4242, body_len);
    const w = fr.writer();
    try w.writeByte(@intCast(map_name.len));
    try w.writeAll(map_name);
    try w.writeInt(i32, @intCast(s.bytes), .little);
    try write(w, t.idNameIterator(), s);
    const framed = try fr.finish();
    try std.testing.expect(framed.len < send_buf.len);
    // Every fragment the reliable channel can carry: 512 parts of 1317 user bytes
    // (src/litenet/peer.zig, src/litenet/packet.zig).
    try std.testing.expect(framed.len < 512 * 1317);

    // Inflate the way the client does (Noemax raw deflate into a growable
    // MemoryStream, asm.il 788690-788728). zdtd's own inbound parser cannot be
    // used here: its 512 KiB inflate cap is a C2S anti-amplification guard, and
    // this S2C blob is nearly a megabyte uncompressed.
    const raw = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqual(@as(u8, 1), framed[5]); // compressed flag
    try std.testing.expectEqual(
        @as(i32, @intCast(framed.len - frame.envelope_len)),
        std.mem.readInt(i32, framed[1..5], .little),
    );
    var in: std.Io.Reader = .fixed(framed[frame.envelope_len..]);
    var out: std.Io.Writer = .fixed(raw);
    var dec: std.compress.flate.Decompress = .init(&in, .raw, &.{});
    const inflated_len = try dec.reader.streamRemaining(&out);
    const stream = raw[0..inflated_len];

    // Package stream: i32 content_len | u16 id | body.
    try std.testing.expectEqual(@as(i32, @intCast(2 + body_len)), std.mem.readInt(i32, stream[0..4], .little));
    try std.testing.expectEqual(@as(u16, 4242), std.mem.readInt(u16, stream[4..6], .little));
    const body = stream[6..];
    try std.testing.expectEqual(@as(u8, 6), body[0]);
    try std.testing.expectEqualStrings("blocks", body[1..7]);
    try std.testing.expectEqual(@as(i32, @intCast(s.bytes)), std.mem.readInt(i32, body[7..11], .little));
    const blob = body[11..];
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, blob[0..4], .little));
    try std.testing.expectEqual(@as(i32, @intCast(s.count)), std.mem.readInt(i32, blob[4..8], .little));
}

test "7 bit string length matches the .NET writer" {
    try std.testing.expectEqual(@as(usize, 1), len7Bit(0));
    try std.testing.expectEqual(@as(usize, 1), len7Bit(127));
    try std.testing.expectEqual(@as(usize, 2), len7Bit(128));
    var name: [200]u8 = @splat('x');
    try std.testing.expectEqual(@as(usize, 202), stringLen(&name));
    var buf: [4]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write7Bit(&w, 200);
    try std.testing.expectEqualSlices(u8, &.{ 0xc8, 0x01 }, buf[0..w.end]);
}
