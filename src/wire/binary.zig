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

    pub fn readI16(self: *Reader) ReadError!i16 {
        if (self.pos + 2 > self.data.len) return error.EndOfStream;
        const v = std.mem.readInt(i16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }

    pub fn readU16(self: *Reader) ReadError!u16 {
        if (self.pos + 2 > self.data.len) return error.EndOfStream;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }

    pub fn readI32(self: *Reader) ReadError!i32 {
        if (self.pos + 4 > self.data.len) return error.EndOfStream;
        const v = std.mem.readInt(i32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    pub fn readU32(self: *Reader) ReadError!u32 {
        if (self.pos + 4 > self.data.len) return error.EndOfStream;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    pub fn readI64(self: *Reader) ReadError!i64 {
        if (self.pos + 8 > self.data.len) return error.EndOfStream;
        const v = std.mem.readInt(i64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }

    pub fn readU64(self: *Reader) ReadError!u64 {
        if (self.pos + 8 > self.data.len) return error.EndOfStream;
        const v = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }

    pub fn readF32(self: *Reader) ReadError!f32 {
        if (self.pos + 4 > self.data.len) return error.EndOfStream;
        const bits = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return @bitCast(bits);
    }

    /// .NET BinaryReader.ReadString: 7-bit encoded length + UTF-8.
    pub fn readString(self: *Reader, buf: []u8) ReadError![]const u8 {
        var len: usize = 0;
        var shift: u6 = 0;
        while (true) {
            const b = try self.readByte();
            len |= @as(usize, b & 0x7F) << shift;
            if ((b & 0x80) == 0) break;
            shift += 7;
            if (shift > 28) return error.InvalidString;
        }
        if (len > buf.len) return error.Overflow;
        if (self.pos + len > self.data.len) return error.EndOfStream;
        @memcpy(buf[0..len], self.data[self.pos..][0..len]);
        self.pos += len;
        return buf[0..len];
    }

    pub fn skipString(self: *Reader) ReadError!void {
        var len: usize = 0;
        var shift: u6 = 0;
        while (true) {
            const b = try self.readByte();
            len |= @as(usize, b & 0x7F) << shift;
            if ((b & 0x80) == 0) break;
            shift += 7;
            if (shift > 28) return error.InvalidString;
        }
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
        try self.writeByte(if (v) 1 else 0);
    }

    pub fn writeI16(self: *Writer, v: i16) error{Overflow}!void {
        try self.ensure(2);
        std.mem.writeInt(i16, self.buf[self.pos..][0..2], v, .little);
        self.pos += 2;
    }

    pub fn writeU16(self: *Writer, v: u16) error{Overflow}!void {
        try self.ensure(2);
        std.mem.writeInt(u16, self.buf[self.pos..][0..2], v, .little);
        self.pos += 2;
    }

    pub fn writeI32(self: *Writer, v: i32) error{Overflow}!void {
        try self.ensure(4);
        std.mem.writeInt(i32, self.buf[self.pos..][0..4], v, .little);
        self.pos += 4;
    }

    pub fn writeU32(self: *Writer, v: u32) error{Overflow}!void {
        try self.ensure(4);
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .little);
        self.pos += 4;
    }

    pub fn writeI64(self: *Writer, v: i64) error{Overflow}!void {
        try self.ensure(8);
        std.mem.writeInt(i64, self.buf[self.pos..][0..8], v, .little);
        self.pos += 8;
    }

    pub fn writeU64(self: *Writer, v: u64) error{Overflow}!void {
        try self.ensure(8);
        std.mem.writeInt(u64, self.buf[self.pos..][0..8], v, .little);
        self.pos += 8;
    }

    pub fn writeF32(self: *Writer, v: f32) error{Overflow}!void {
        try self.ensure(4);
        const bits: u32 = @bitCast(v);
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], bits, .little);
        self.pos += 4;
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
    var shift: u5 = 0;
    while (true) {
        const b = try r.readByte();
        result |= @as(u32, b & 0x7F) << shift;
        if ((b & 0x80) == 0) break;
        shift += 7;
        if (shift > 28) return error.Overflow;
    }
    return result;
}

test "string roundtrip" {
    var buf: [64]u8 = undefined;
    var w: Writer = .{ .buf = &buf };
    try w.writeString("V 3.0.1");
    var r: Reader = .{ .data = w.written() };
    var sbuf: [32]u8 = undefined;
    const s = try r.readString(&sbuf);
    try std.testing.expectEqualStrings("V 3.0.1", s);
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
