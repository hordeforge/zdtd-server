//! PlatformUserIdentifierAbs wire codec (stock V3.1.0 b14).
//!
//! One codec for every package that carries a platform identity (login,
//! PersistentPlayerData, SetBlock, ally). Each ad-hoc copy of these four fields
//! is a chance to drift from stock, so callers use this module and nothing else.
//!
//! `PlatformUserIdentifierAbs::FromStream(BinaryReader, errorOnEmpty,
//! inclCustomData)` (asm.il 30604): bool present, and a false bool is the entire
//! value (the identity is null). Otherwise u8 UserIdentifierVersion (read then
//! popped, never used), string PlatformIdentifierString, string
//! ReadablePlatformUserIdentifier, then `ReadCustomData` when inclCustomData.
//!
//! `PlatformUserIdentifierExtensions::ToStream` (asm.il 31206): a null identity
//! writes a lone 0 byte; otherwise u8 1 (the present bool), u8 1
//! (UserIdentifierVersion), platform string, id string.
//!
//! `WriteCustomData` / `ReadCustomData` (asm.il 30544 / 30553) are empty base
//! bodies with no override anywhere in the assembly, so inclCustomData costs
//! zero bytes on the wire and needs no per-platform branch here.

const std = @import("std");
const binary = @import("binary.zig");

/// `PlatformUserIdentifierAbs.UserIdentifierVersion` (asm.il 30507). Stock reads
/// it and pops it, but writes 1, so zdtd writes 1 to stay byte-identical.
pub const user_identifier_version: u8 = 1;

/// PlatformIdentifierString is an `EPlatformIdentifier` name (asm.il 2661453):
/// None, Local, EOS, Steam, XBL, PSN, EGS, LAN. Longest is 5 bytes.
pub const max_platform_len = 16;
/// Steam ids are 17 digits, EOS ProductUserIds 32 hex chars. Anything past this
/// is not a real identity, so it is rejected rather than truncated.
pub const max_id_len = 64;
/// Capacity of the "platform:id" composite key used by the operator lists
/// (admin/whitelist/ban). The id fields are capped at max_id_len but the
/// composite adds the platform + separator, so a key buffer sized to
/// max_id_len alone overflows for a max-length identity - which at the join
/// whitelist gate used to fail OPEN (the bufPrint catch skipped the gate).
pub const max_composite_len = max_platform_len + 1 + max_id_len;

pub const Id = struct {
    /// EPlatformIdentifier name; the client resolves it via FromPlatformAndId
    /// (asm.il 30960) and drops the whole identity when it does not parse.
    platform: []const u8,
    id: []const u8,

    pub fn eql(a: Id, b: Id) bool {
        return std.mem.eql(u8, a.platform, b.platform) and std.mem.eql(u8, a.id, b.id);
    }
};

/// Read one identity into caller-supplied buffers. Null when the leading bool is
/// false, which is a legitimate value and not an error (asm.il 30604).
pub fn read(r: *binary.Reader, plat_buf: []u8, id_buf: []u8) binary.ReadError!?Id {
    if (!try r.readBool()) return null;
    _ = try r.readByte(); // UserIdentifierVersion: stock reads then pops it
    const platform = try r.readString(plat_buf);
    const id = try r.readString(id_buf);
    return .{ .platform = platform, .id = id };
}

/// Advance past one identity without copying it (callers that only need the
/// fields after it, e.g. SetBlock's change list).
pub fn skip(r: *binary.Reader) binary.ReadError!void {
    if (!try r.readBool()) return;
    _ = try r.readByte();
    try r.skipString();
    try r.skipString();
}

pub fn write(w: *binary.Writer, v: ?Id) error{Overflow}!void {
    const u = v orelse return w.writeByte(0);
    try w.writeByte(1); // present bool
    try w.writeByte(user_identifier_version);
    try w.writeString(u.platform);
    try w.writeString(u.id);
}

/// Fixed-size owned identity for per-connection storage. `present = false` is a
/// legitimate state, not an error: a client running without a platform session
/// (EAC off) and zdtd's own loadgen bots both send a null identifier, and stock
/// accepts that.
pub const Stored = struct {
    platform_buf: [max_platform_len]u8 = undefined,
    id_buf: [max_id_len]u8 = undefined,
    platform_len: u8 = 0,
    id_len: u8 = 0,
    present: bool = false,

    /// Copies `v` in. Overlong strings are rejected: silently truncating an id
    /// would let two different accounts collapse onto one identity.
    pub fn set(self: *Stored, v: ?Id) error{Overflow}!void {
        const u = v orelse {
            self.* = .{};
            return;
        };
        if (u.platform.len > max_platform_len or u.id.len > max_id_len) return error.Overflow;
        @memcpy(self.platform_buf[0..u.platform.len], u.platform);
        @memcpy(self.id_buf[0..u.id.len], u.id);
        self.platform_len = @intCast(u.platform.len);
        self.id_len = @intCast(u.id.len);
        self.present = true;
    }

    pub fn get(self: *const Stored) ?Id {
        if (!self.present) return null;
        return .{
            .platform = self.platform_buf[0..self.platform_len],
            .id = self.id_buf[0..self.id_len],
        };
    }

    pub fn matches(self: *const Stored, other: Id) bool {
        const mine = self.get() orelse return false;
        return mine.eql(other);
    }
};

test "null identity is a lone zero byte both ways" {
    var buf: [8]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try write(&w, null);
    try std.testing.expectEqualSlices(u8, &[_]u8{0}, w.written());

    var r: binary.Reader = .{ .data = w.written() };
    try std.testing.expect((try read(&r, &buf, &buf)) == null);
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "present identity round-trips with stock byte shape" {
    var buf: [64]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try write(&w, .{ .platform = "Steam", .id = "76561198000000001" });
    const body = w.written();
    // present bool | version | 7-bit len + "Steam" | 7-bit len + id
    try std.testing.expectEqual(@as(u8, 1), body[0]);
    try std.testing.expectEqual(user_identifier_version, body[1]);
    try std.testing.expectEqual(@as(u8, 5), body[2]);
    try std.testing.expectEqualStrings("Steam", body[3..8]);

    var plat: [max_platform_len]u8 = undefined;
    var id: [max_id_len]u8 = undefined;
    var r: binary.Reader = .{ .data = body };
    const got = (try read(&r, &plat, &id)).?;
    try std.testing.expectEqualStrings("Steam", got.platform);
    try std.testing.expectEqualStrings("76561198000000001", got.id);
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "empty platform and empty id are readable" {
    var buf: [16]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try write(&w, .{ .platform = "", .id = "" });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 1, 0, 0 }, w.written());

    var plat: [max_platform_len]u8 = undefined;
    var id: [max_id_len]u8 = undefined;
    var r: binary.Reader = .{ .data = w.written() };
    const got = (try read(&r, &plat, &id)).?;
    try std.testing.expectEqual(@as(usize, 0), got.platform.len);
    try std.testing.expectEqual(@as(usize, 0), got.id.len);
}

test "truncated identity at every boundary is EndOfStream" {
    var buf: [64]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    try write(&w, .{ .platform = "EOS", .id = "0123456789abcdef" });
    const body = w.written();
    var plat: [max_platform_len]u8 = undefined;
    var id: [max_id_len]u8 = undefined;
    var cut: usize = 1;
    while (cut < body.len) : (cut += 1) {
        var r: binary.Reader = .{ .data = body[0..cut] };
        try std.testing.expectError(error.EndOfStream, read(&r, &plat, &id));
        var rs: binary.Reader = .{ .data = body[0..cut] };
        try std.testing.expectError(error.EndOfStream, skip(&rs));
    }
    // Empty body has no present bool at all.
    var r0: binary.Reader = .{ .data = body[0..0] };
    try std.testing.expectError(error.EndOfStream, read(&r0, &plat, &id));
}

test "length prefix longer than the body is EndOfStream" {
    // present | version | platform len 10 with only 3 bytes behind it
    const body = [_]u8{ 1, 1, 10, 'E', 'O', 'S' };
    var plat: [max_platform_len]u8 = undefined;
    var id: [max_id_len]u8 = undefined;
    var r: binary.Reader = .{ .data = &body };
    try std.testing.expectError(error.EndOfStream, read(&r, &plat, &id));
    var rs: binary.Reader = .{ .data = &body };
    try std.testing.expectError(error.EndOfStream, skip(&rs));

    // A length past the read buffer is Overflow, checked before the body fit.
    const wide = [_]u8{ 1, 1, max_platform_len + 1, 'E', 'O', 'S' };
    var rw: binary.Reader = .{ .data = &wide };
    try std.testing.expectError(error.Overflow, read(&rw, &plat, &id));

    // Overlong 7-bit length prefix is rejected as a bad string, not read.
    const overlong = [_]u8{ 1, 1, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 };
    var ro: binary.Reader = .{ .data = &overlong };
    try std.testing.expectError(error.InvalidString, read(&ro, &plat, &id));
    var rso: binary.Reader = .{ .data = &overlong };
    try std.testing.expectError(error.InvalidString, skip(&rso));
}

test "id longer than the read buffer is rejected, not truncated" {
    var buf: [128]u8 = undefined;
    var w: binary.Writer = .{ .buf = &buf };
    const long_id = "x" ** (max_id_len + 1);
    try write(&w, .{ .platform = "Steam", .id = long_id });
    var plat: [max_platform_len]u8 = undefined;
    var id: [max_id_len]u8 = undefined;
    var r: binary.Reader = .{ .data = w.written() };
    try std.testing.expectError(error.Overflow, read(&r, &plat, &id));
    // skip does not copy, so it still walks the same bytes cleanly.
    var rs: binary.Reader = .{ .data = w.written() };
    try skip(&rs);
    try std.testing.expectEqual(@as(usize, 0), rs.remaining());
}

test "Stored holds, compares and clears identities" {
    var s: Stored = .{};
    try std.testing.expect(s.get() == null);
    try std.testing.expect(!s.matches(.{ .platform = "Steam", .id = "1" }));

    try s.set(.{ .platform = "EOS", .id = "abc" });
    const got = s.get().?;
    try std.testing.expectEqualStrings("EOS", got.platform);
    try std.testing.expectEqualStrings("abc", got.id);
    try std.testing.expect(s.matches(.{ .platform = "EOS", .id = "abc" }));
    // Same id on a different platform is a different account.
    try std.testing.expect(!s.matches(.{ .platform = "Steam", .id = "abc" }));

    try std.testing.expectError(error.Overflow, s.set(.{ .platform = "EOS", .id = "y" ** (max_id_len + 1) }));
    try s.set(null);
    try std.testing.expect(s.get() == null);
}

test "max-length platform and id survive storage" {
    var s: Stored = .{};
    const plat = "P" ** max_platform_len;
    const id = "I" ** max_id_len;
    try s.set(.{ .platform = plat, .id = id });
    const got = s.get().?;
    try std.testing.expectEqualStrings(plat, got.platform);
    try std.testing.expectEqualStrings(id, got.id);
}
