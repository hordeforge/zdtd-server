//! Config-file body: name + len + bytes with null form, and the
//! pinning test.
//!
//! Split out of the packages.zig facade (same builder, same test);
//! import via `packages.stock_configfile` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// Stock NetPackageConfigFile body (RE IL=25, protocol-packages.md §...):
/// `name` (7-bit string), then dataLen i32 = -1 when data is null (client
/// loads its own file; LoadClientFile rows such as archetypes), else the
/// Deflate-compressed patched config bytes. Package-level `Compress`=true
/// (G7) is handled by the framer at the send site.
pub fn buildConfigFileBody(buf: []u8, name: []const u8, data: ?[]const u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeString(name);
    if (data) |d| {
        try w.writeI32(@intCast(d.len));
        try w.writeBytes(d);
    } else {
        try w.writeI32(-1);
    }
    return w.written();
}

test "buildConfigFileBody pins name + len + bytes and null form" {
    var buf: [512]u8 = undefined;
    const with_data = try buildConfigFileBody(&buf, "blocks", &[_]u8{ 1, 2, 3, 4 });
    // 7-bit name len 6 | "blocks" | i32 len 4 | 4 bytes
    try std.testing.expectEqualSlices(u8, &.{
        6, 'b', 'l', 'o', 'c', 'k', 's',
        4, 0,   0,   0,   1,   2,   3,
        4,
    }, with_data);
    const null_form = try buildConfigFileBody(&buf, "archetypes", null);
    try std.testing.expectEqualSlices(u8, &.{
        10,   'a',  'r',  'c',  'h', 'e', 't', 'y', 'p', 'e', 's',
        0xff, 0xff, 0xff, 0xff,
    }, null_form);
}
