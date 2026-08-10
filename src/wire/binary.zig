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

test "le ints" {
    var buf: [16]u8 = undefined;
    var w: Writer = .{ .buf = &buf };
    try w.writeI32(-1);
    try w.writeU16(0xABCD);
    var r: Reader = .{ .data = w.written() };
    try std.testing.expectEqual(@as(i32, -1), try r.readI32());
    try std.testing.expectEqual(@as(u16, 0xABCD), try r.readU16());
}
