//! Little-endian readers/writers matching .NET BinaryReader/Writer (7-bit strings).

const std = @import("std");

pub const ReadError = error{ EndOfStream, InvalidString, Overflow };

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn remaining(self: *const Reader) usize {
        return self.data.len - self.pos;
    }

    pub fn readByte(self: *Reader) ReadError!u8 {
        if (self.pos >= self.data.len) return error.EndOfStream;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    pub fn readBool(self: *Reader) ReadError!bool {
        return (try self.readByte()) != 0;
    }

    fn readInt(self: *Reader, comptime T: type) ReadError!T {
        const n = @sizeOf(T);
        if (self.pos + n > self.data.len) return error.EndOfStream;
        const v = std.mem.readInt(T, self.data[self.pos..][0..n], .little);
        self.pos += n;
        return v;
    }

    pub fn readI16(self: *Reader) ReadError!i16 {
        return self.readInt(i16);
    }

    pub fn readU16(self: *Reader) ReadError!u16 {
        return self.readInt(u16);
    }

    pub fn readI32(self: *Reader) ReadError!i32 {
        return self.readInt(i32);
    }

    pub fn readU32(self: *Reader) ReadError!u32 {
        return self.readInt(u32);
    }

    pub fn readI64(self: *Reader) ReadError!i64 {
        return self.readInt(i64);
    }

    pub fn readU64(self: *Reader) ReadError!u64 {
        return self.readInt(u64);
    }

    pub fn readF32(self: *Reader) ReadError!f32 {
        return @bitCast(try self.readInt(u32));
    }

    /// .NET BinaryReader 7-bit string length; overlong prefix → InvalidString.
    fn readStringLen(self: *Reader) ReadError!usize {
        // Same encoding as read7BitEncodedInt; map Overflow so string paths keep
        // InvalidString (callers and tests distinguish bad length from buffer fit).
        const n = read7BitEncodedInt(self) catch |err| switch (err) {
            error.Overflow => return error.InvalidString,
            else => |e| return e,
        };
        return n;
    }

    /// .NET BinaryReader.ReadString: 7-bit encoded length + UTF-8.
    pub fn readString(self: *Reader, buf: []u8) ReadError![]const u8 {
        const len = try self.readStringLen();
        if (len > buf.len) return error.Overflow;
        if (self.pos + len > self.data.len) return error.EndOfStream;
        @memcpy(buf[0..len], self.data[self.pos..][0..len]);
        self.pos += len;
        return buf[0..len];
    }

    /// readString that keeps the prefix of a string longer than `buf` instead
    /// of failing. The whole field is still consumed, so the reader stays
    /// aligned for the fields after it. Use where stock writes an unbounded
    /// .NET string that zdtd stores in a fixed buffer and the value is display
    /// or key material rather than something parsed further; a hard `Overflow`
    /// there would abandon the rest of the body.
    pub fn readStringTruncating(self: *Reader, buf: []u8) ReadError![]const u8 {
        const len = try self.readStringLen();
        if (self.pos + len > self.data.len) return error.EndOfStream;
        var keep = @min(len, buf.len);
        if (keep < len) {
            while (keep > 0 and self.data[self.pos + keep] & 0xc0 == 0x80) keep -= 1;
        }
        @memcpy(buf[0..keep], self.data[self.pos..][0..keep]);
        self.pos += len;
        return buf[0..keep];
    }

    pub fn skipString(self: *Reader) ReadError!void {
        const len = try self.readStringLen();
        if (self.pos + len > self.data.len) return error.EndOfStream;
        self.pos += len;
    }
};

pub const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn written(self: *Writer) []u8 {
        return self.buf[0..self.pos];
    }

    pub fn ensure(self: *Writer, n: usize) error{Overflow}!void {
        if (self.pos + n > self.buf.len) return error.Overflow;
    }

    pub fn writeByte(self: *Writer, b: u8) error{Overflow}!void {
        try self.ensure(1);
        self.buf[self.pos] = b;
        self.pos += 1;
    }

    pub fn writeBool(self: *Writer, v: bool) error{Overflow}!void {
        try self.writeByte(@intFromBool(v));
    }

    fn writeInt(self: *Writer, comptime T: type, v: T) error{Overflow}!void {
        const n = @sizeOf(T);
        try self.ensure(n);
        std.mem.writeInt(T, self.buf[self.pos..][0..n], v, .little);
        self.pos += n;
    }

    pub fn writeI16(self: *Writer, v: i16) error{Overflow}!void {
        return self.writeInt(i16, v);
    }

    pub fn writeU16(self: *Writer, v: u16) error{Overflow}!void {
        return self.writeInt(u16, v);
    }

    pub fn writeI32(self: *Writer, v: i32) error{Overflow}!void {
        return self.writeInt(i32, v);
    }

    pub fn writeU32(self: *Writer, v: u32) error{Overflow}!void {
        return self.writeInt(u32, v);
    }

    pub fn writeI64(self: *Writer, v: i64) error{Overflow}!void {
        return self.writeInt(i64, v);
    }

    pub fn writeU64(self: *Writer, v: u64) error{Overflow}!void {
        return self.writeInt(u64, v);
    }

    pub fn writeF32(self: *Writer, v: f32) error{Overflow}!void {
        return self.writeInt(u32, @bitCast(v));
    }

    pub fn writeBytes(self: *Writer, b: []const u8) error{Overflow}!void {
        try self.ensure(b.len);
        @memcpy(self.buf[self.pos..][0..b.len], b);
        self.pos += b.len;
    }

    pub fn writeString(self: *Writer, s: []const u8) error{Overflow}!void {
        try self.write7BitEncodedInt(@intCast(s.len));
        try self.writeBytes(s);
    }

    /// .NET BinaryWriter.Write7BitEncodedInt
    pub fn write7BitEncodedInt(self: *Writer, value: u32) error{Overflow}!void {
        var v = value;
        // Both truncations are provably lossless: the mask keeps the byte under
        // 0x80 before the continuation bit, and the loop exits with v < 0x80.
        // @truncate (not @intCast) keeps the wire encode path branch-free.
        while (v >= 0x80) {
            try self.writeByte(@truncate((v & 0x7F) | 0x80));
            v >>= 7;
        }
        try self.writeByte(@truncate(v));
    }
};

/// .NET BinaryReader.Read7BitEncodedInt (unsigned payload in 7-bit groups).
pub fn read7BitEncodedInt(r: *Reader) ReadError!u32 {
    var result: u32 = 0;
    var shift: u32 = 0;
    while (true) {
        const b = try r.readByte();
        result |= @as(u32, b & 0x7F) << @intCast(shift);
        if ((b & 0x80) == 0) break;
        shift += 7;
        if (shift > 28) return error.Overflow;
    }
    return result;
}

test "string roundtrip" {
    var buf: [64]u8 = undefined;
    var w: Writer = .{ .buf = &buf };
    try w.writeString("V 3.1.0");
    try w.writeString("");
    var r: Reader = .{ .data = w.written() };
    var sbuf: [32]u8 = undefined;
    const s = try r.readString(&sbuf);
    try std.testing.expectEqualStrings("V 3.1.0", s);
    const empty = try r.readString(&sbuf);
    try std.testing.expectEqualStrings("", empty);
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "7bit int encodes the byte-width boundaries like BinaryWriter" {
    // The `>=` in the encoder loop is what makes 0x80 spill into a second
    // byte, and nothing pinned it: changing it to `>` writes a 128-byte
    // string's length as a single 0x80, which a .NET reader takes as a
    // continuation byte and then reads the payload from the wrong offset.
    // Every string of 128 bytes or more rides on this - server names, chat,
    // quest ids. Expected encodings are BinaryWriter.Write7BitEncodedInt.
    const cases = [_]struct { u32, []const u8 }{
        .{ 0, &.{0x00} },
        .{ 0x7F, &.{0x7F} }, // last single byte
        .{ 0x80, &.{ 0x80, 0x01 } }, // first two-byte value
        .{ 0x3FFF, &.{ 0xFF, 0x7F } }, // last two-byte value
        .{ 0x4000, &.{ 0x80, 0x80, 0x01 } }, // first three-byte value
        .{ 0xFFFFFFFF, &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0x0F } }, // five bytes, the .NET max
    };
    for (cases) |c| {
        var buf: [8]u8 = undefined;
        var w: Writer = .{ .buf = &buf };
        try w.write7BitEncodedInt(c[0]);
        try std.testing.expectEqualSlices(u8, c[1], w.written());

        var r: Reader = .{ .data = w.written() };
        try std.testing.expectEqual(c[0], try read7BitEncodedInt(&r));
        try std.testing.expectEqual(@as(usize, 0), r.remaining());
    }
}

test "strings count UTF-8 bytes, not characters, across the width boundary" {
    // BinaryWriter.Write(string) prefixes the UTF-8 *byte* count. Counting
    // characters instead would under-read every non-ASCII string by the number
    // of continuation bytes and shift every field after it. Nothing exercised
    // a multi-byte string, so the distinction was untested.
    var buf: [256]u8 = undefined;
    var w: Writer = .{ .buf = &buf };
    const utf8 = "Schöner Server"; // 14 characters, 15 bytes
    try std.testing.expectEqual(@as(usize, 15), utf8.len);
    try w.writeString(utf8);
    try std.testing.expectEqual(@as(u8, 15), w.written()[0]); // one length byte

    var r: Reader = .{ .data = w.written() };
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings(utf8, try r.readString(&out));
    try std.testing.expectEqual(@as(usize, 0), r.remaining());

    // A string whose byte length is exactly the two-byte boundary: the prefix
    // has to spill, and the payload has to start right after both bytes.
    const long: [128]u8 = @splat('x');
    var w2: Writer = .{ .buf = &buf };
    try w2.writeString(&long);
    const framed = w2.written();
    try std.testing.expectEqual(@as(usize, 2 + long.len), framed.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x01 }, framed[0..2]);

    var r2: Reader = .{ .data = framed };
    var out2: [128]u8 = undefined; // distinct from `buf`: readString memcpys
    try std.testing.expectEqualStrings(&long, try r2.readString(&out2));
    try std.testing.expectEqual(@as(usize, 0), r2.remaining());
}

test "7bit int rejects overlong encoding without overflowing shift" {
    var r: Reader = .{ .data = &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F } };
    try std.testing.expectError(error.Overflow, read7BitEncodedInt(&r));
}

test "string readers reject overlong length prefixes" {
    const overlong = [_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 };
    var buf: [1]u8 = undefined;

    var read: Reader = .{ .data = &overlong };
    try std.testing.expectError(error.InvalidString, read.readString(&buf));

    var skip: Reader = .{ .data = &overlong };
    try std.testing.expectError(error.InvalidString, skip.skipString());
}

test "string readers reject truncation and preserve cursor at payload" {
    var truncated: Reader = .{ .data = &.{ 3, 'a', 'b' } };
    var buf: [3]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, truncated.readString(&buf));
    try std.testing.expectEqual(@as(usize, 1), truncated.pos);

    var too_small: Reader = .{ .data = &.{ 3, 'a', 'b', 'c' } };
    var short: [2]u8 = undefined;
    try std.testing.expectError(error.Overflow, too_small.readString(&short));
    try std.testing.expectEqual(@as(usize, 1), too_small.pos);

    var skip_truncated: Reader = .{ .data = &.{ 2, 'a' } };
    try std.testing.expectError(error.EndOfStream, skip_truncated.skipString());
}

test "readStringTruncating keeps the prefix and stays aligned for the next field" {
    // An over-long string must not abandon the fields behind it: the cursor
    // lands on the trailing marker either way.
    var r: Reader = .{ .data = &.{ 5, 'a', 'b', 'c', 'd', 'e', 0x2a } };
    var small: [2]u8 = undefined;
    const kept = try r.readStringTruncating(&small);
    try std.testing.expectEqualStrings("ab", kept);
    try std.testing.expectEqual(@as(u8, 0x2a), try r.readByte());

    // A string that fits reads whole, exactly like readString.
    var r2: Reader = .{ .data = &.{ 3, 'x', 'y', 'z', 0x2a } };
    var big: [8]u8 = undefined;
    try std.testing.expectEqualStrings("xyz", try r2.readStringTruncating(&big));
    try std.testing.expectEqual(@as(u8, 0x2a), try r2.readByte());

    // Truncation of the payload itself is still an error, not a short read.
    var r3: Reader = .{ .data = &.{ 4, 'a', 'b' } };
    try std.testing.expectError(error.EndOfStream, r3.readStringTruncating(&big));
}

test "readStringTruncating preserves UTF-8 boundaries at every byte cap" {
    const cases = [_][]const u8{ "", "plain", "caf\u{e9}", "\u{65}\u{301}", "\u{65e5}\u{672c}", "\u{1f680}" };
    for (cases) |text| {
        var framed: [64]u8 = undefined;
        var w: Writer = .{ .buf = &framed };
        try w.writeString(text);
        try w.writeByte(0x2a);
        var out: [64]u8 = undefined;
        for (0..text.len + 2) |cap| {
            var r: Reader = .{ .data = w.written() };
            const kept = try r.readStringTruncating(out[0..cap]);
            try std.testing.expect(std.unicode.utf8ValidateSlice(kept));
            var expected: usize = 0;
            var iter = (try std.unicode.Utf8View.init(text)).iterator();
            while (iter.nextCodepointSlice()) |cp| {
                if (expected + cp.len > cap) break;
                expected += cp.len;
            }
            try std.testing.expectEqualStrings(text[0..expected], kept);
            try std.testing.expectEqual(@as(u8, 0x2a), try r.readByte());
            try std.testing.expectEqual(@as(usize, 0), r.remaining());
        }
    }
}

test "f32 is a little-endian bit pattern, sign preserved" {
    // BinaryWriter.Write(float) emits the IEEE-754 bits little-endian, so the
    // wire form is a bit pattern rather than a numeric value: -0.0 must not
    // collapse to 0.0. The existing float tests only round-trip ordinary
    // values, and a roundtrip agrees with itself whatever the byte order is,
    // so pin one known pattern outright.
    var buf: [32]u8 = undefined;
    var w: Writer = .{ .buf = &buf };
    try w.writeF32(1.0);
    // IEEE-754 1.0 is 0x3F800000, little-endian on the wire.
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x80, 0x3F }, w.written()[0..4]);

    try w.writeF32(-0.0);
    try w.writeF32(std.math.inf(f32));
    try w.writeF32(-std.math.inf(f32));

    var r: Reader = .{ .data = w.written() };
    try std.testing.expectEqual(@as(f32, 1.0), try r.readF32());
    // -0.0 == 0.0 compares true, so check the sign bit the wire carried.
    const neg_zero = try r.readF32();
    try std.testing.expectEqual(@as(u32, 0x80000000), @as(u32, @bitCast(neg_zero)));
    try std.testing.expectEqual(std.math.inf(f32), try r.readF32());
    try std.testing.expectEqual(-std.math.inf(f32), try r.readF32());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "signed ints ride the wire as little-endian two's complement" {
    // The existing `le ints` case does catch a byte swap, through its 0xABCD.
    // What it cannot see is a value-dependent fault: -1 is all-ones and 0xABCD
    // is positive, so a writer that mishandles only the signed minimum - the
    // one value where negating to a magnitude overflows - passes it. Clamping
    // just minInt was checked against both tests: this one fails, `le ints`
    // stays green.
    var buf: [32]u8 = undefined;
    var w: Writer = .{ .buf = &buf };
    try w.writeI32(std.math.minInt(i32));
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x00, 0x80 }, w.written()[0..4]);
    try w.writeI32(std.math.maxInt(i32));
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xFF, 0xFF, 0x7F }, w.written()[4..8]);
    try w.writeI16(std.math.minInt(i16));
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x80 }, w.written()[8..10]);
    try w.writeI64(std.math.minInt(i64));

    var r: Reader = .{ .data = w.written() };
    try std.testing.expectEqual(std.math.minInt(i32), try r.readI32());
    try std.testing.expectEqual(std.math.maxInt(i32), try r.readI32());
    try std.testing.expectEqual(std.math.minInt(i16), try r.readI16());
    try std.testing.expectEqual(std.math.minInt(i64), try r.readI64());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "le ints" {
    var buf: [16]u8 = undefined;
    var w: Writer = .{ .buf = &buf };
    try w.writeI32(-1);
    try w.writeU16(0xABCD);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xCD, 0xAB }, w.written());
    var r: Reader = .{ .data = w.written() };
    try std.testing.expectEqual(@as(i32, -1), try r.readI32());
    try std.testing.expectEqual(@as(u16, 0xABCD), try r.readU16());
}
