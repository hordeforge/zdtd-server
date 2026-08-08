//! NetPackageEntityAddExpClient body (ToClient XP grant; RE
//! ../7dtd-research/il/netpackages-v3.1.0/NetPackageEntityAddExpClient_il.txt).
//!
//! `write` order after the package name: entityId i32, xp i32, xpType i16,
//! includeItem bool, then ItemValue only when includeItem. ProcessPackage
//! (IL=36) maps xpType == 0 to the "_xpFromKill" tag and anything else to
//! "_xpOther", so kill XP must use 0. zdtd never sends the optional ItemValue
//! (includeItem=false): the server grants plain XP, not item-tied XP.

const std = @import("std");
const binary = @import("binary.zig");

/// Stock XPTypes enum; the wire carries the i16 value. 0 = Kill (the client
/// tags it `_xpFromKill`), any other value = Other (`_xpOther`).
pub const xp_type_kill: i16 = 0;
pub const xp_type_other: i16 = 1;

pub const AddExpArgs = struct {
    entity_id: i32,
    xp: i32,
    xp_type: i16 = xp_type_other,
};

/// NetPackageEntityAddExpClient body: 4 + 4 + 2 + 1 = 11 bytes, no ItemValue.
pub fn buildAddExpClientBody(buf: []u8, args: AddExpArgs) ![]u8 {
    var w = binary.Writer{ .buf = buf };
    try w.writeI32(args.entity_id);
    try w.writeI32(args.xp);
    try w.writeI16(args.xp_type);
    try w.writeBool(false);
    return w.written();
}

test "add exp client body is the 11-byte stock shape" {
    var buf: [16]u8 = undefined;
    const body = try buildAddExpClientBody(&buf, .{ .entity_id = 42, .xp = 90, .xp_type = xp_type_kill });
    try std.testing.expectEqual(@as(usize, 11), body.len);
    var r = binary.Reader{ .data = body };
    try std.testing.expectEqual(@as(i32, 42), try r.readI32());
    try std.testing.expectEqual(@as(i32, 90), try r.readI32());
    try std.testing.expectEqual(@as(i16, 0), try r.readI16());
    try std.testing.expectEqual(false, try r.readBool());
}
