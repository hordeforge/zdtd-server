//! Player-denied body: EKickReason subset, the stock denied-body
//! builder, and the field-order test.
//!
//! Split out of the packages.zig facade (same builder, same test);
//! import via `packages.stock_denied` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");


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
