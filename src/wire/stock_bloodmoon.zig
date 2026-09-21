//! Bloodmoon-music body: single eligibility bool with the layout test.
//!
//! Split out of the packages.zig facade (same builder, same test);
//! import via `packages.stock_bloodmoon` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// NetPackageBloodmoonMusic (Assembly-CSharp NetPackageBloodmoonMusic::write): after the
/// base NetPackage header the payload is a single WriteBool(IsBloodMoonMusicEligible).
/// GetLength()=1, PackageDirection=ToClient. Sent per-player by DynamicMusic.Conductor.Update
/// in stock (per-player eligibility); our server broadcasts one global bool as an approximation.
pub fn buildBloodmoonMusicBody(buf: []u8, eligible: bool) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(eligible);
    return w.written();
}

test "BloodmoonMusic body is a single eligibility bool" {
    var buf: [4]u8 = undefined;
    const on = try buildBloodmoonMusicBody(&buf, true);
    try std.testing.expectEqual(@as(usize, 1), on.len);
    try std.testing.expectEqual(@as(u8, 1), on[0]);
    const off = try buildBloodmoonMusicBody(&buf, false);
    try std.testing.expectEqual(@as(usize, 1), off.len);
    try std.testing.expectEqual(@as(u8, 0), off[0]);
}
