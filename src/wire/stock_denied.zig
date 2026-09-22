//! Player-denied body: EKickReason subset, the stock denied-body
//! builder, and the field-order test.
//!
//! Split out of the packages.zig facade (same builder, same test);
//! import via `packages.stock_denied` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");
const framed = @import("stock_frame.zig").framed;

/// GameUtils/EKickReason (asm.il:1913681-1913720). Only the values zdtd emits:
/// an operator `kick` and a server-side guard-policy decision. zdtd has no EAC
/// integration, so the Eac* reasons are never sent.
pub const KickReason = enum(i32) {
    /// EKickReason.ManualKick (10), RE `protocol-packages.md` "EKickReason";
    /// stock also uses it for a platform-blocked enter.
    manual_kick = 0x0A,
    /// 16. **Name and client-facing string unverified.** The RE records 35
    /// values and names ten of them; 16 is in range but is not one of the
    /// named ones, and no retained dump carries the full enum, so what a
    /// stock client renders for it is unknown. Only the guard-policy kick
    /// (`game/guard.zig`) sends it, and that call fills the custom reason
    /// string, which is what an operator actually reads. Re-derive the label
    /// from a fresh enum dump before relying on it.
    mod_decision = 0x10,
    /// EKickReason.VersionMismatch (asm.il GameUtils_EKickReason): the
    /// client's compatibilityVersion differs from LongStringNoBuild.
    version_mismatch = 4,
    /// EKickReason.PlayerLimitExceeded: the server is full (AuthorizationManager).
    player_limit_exceeded = 5,
    /// EKickReason.Banned: the source identity/IP is banned.
    banned = 6,
    /// EKickReason.NotOnWhitelist: the identity is not on the (enabled)
    /// whitelist and is not an admin (BansAndWhitelistAuthorizer, IL=71).
    not_on_whitelist = 7,
};

/// Stock NetPackagePlayerDenied body (asm.il:827055-827090):
///   i32 reason | i32 apiResponseEnum | i64 banUntil (DateTime.ToBinary) |
///   string customReason (BinaryWriter 7-bit length prefix).
/// The u16 package id belongs to the base `NetPackage::write`
/// (asm.il:800444-800456), which `frame.framePackage` already emits, so it must
/// NOT be repeated here. `banUntil = 0` is stock's default `initobj DateTime`
/// (asm.il:1918620-1918630), i.e. a kick with no ban.
pub fn buildPlayerDeniedBody(
    buf: []u8,
    reason: KickReason,
    api_response: i32,
    ban_until_binary: i64,
    custom_reason: []const u8,
) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(@intFromEnum(reason));
    try w.writeI32(api_response);
    try w.writeI64(ban_until_binary);
    try w.writeString(custom_reason);
    return w.written();
}

test "PlayerDenied body matches stock field order and excludes the package id" {
    var buf: [64]u8 = undefined;
    const body = try buildPlayerDeniedBody(&buf, .mod_decision, 0, 0, "abc");
    // i32 + i32 + i64 + (1-byte 7-bit length + 3 bytes) = 20 bytes, which is
    // also stock GetLength() (asm.il:827105-827110) for a 3-char reason.
    try std.testing.expectEqual(@as(usize, 20), body.len);
    var r: binary.Reader = .{ .data = body };
    try std.testing.expectEqual(@as(i32, 0x10), try r.readI32());
    try std.testing.expectEqual(@as(i32, 0), try r.readI32());
    try std.testing.expectEqual(@as(i64, 0), try r.readI64());
    try std.testing.expectEqual(@as(u32, 3), try binary.read7BitEncodedInt(&r));
    try std.testing.expectEqualStrings("abc", body[body.len - 3 ..]);

    // framed() appends the body verbatim after the u16 package id that the base
    // NetPackage::write emits; the body must not carry a second copy of it.
    var framed_buf: [64]u8 = undefined;
    const f = try framed(&framed_buf, "NetPackagePlayerDenied", body);
    try std.testing.expect(std.mem.endsWith(u8, f, body));
    // frame header is 13 bytes (frame.framePackage), then u16 id, then body.
    try std.testing.expectEqual(@as(usize, 13 + 2) + body.len, f.len);

    const manual = try buildPlayerDeniedBody(&buf, .manual_kick, 0, 0, "");
    try std.testing.expectEqual(@as(i32, 0x0A), std.mem.readInt(i32, manual[0..4], .little));
    try std.testing.expectEqual(@as(usize, 17), manual.len);
}
