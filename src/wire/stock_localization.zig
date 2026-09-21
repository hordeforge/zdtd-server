//! Localization body: seqNr + totalParts + dataLen + bytes with null form.
//!
//! Split out of the packages.zig facade (same builder, moved verbatim);
//! its test stays in the facade where the suite already exercises it.
//! import via `packages.stock_localization` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// Stock `NetPackageLocalization` body (write IL=30): seqNr i32 | totalParts
/// i32 | dataLen i32 (-1 when null) | data bytes. `Compress()` is false for
/// this package (`get_Compress` IL=2), so the frame stays uncompressed even
/// though the payload itself is stock's raw-Deflate patch blob.
pub fn buildLocalizationBody(buf: []u8, seq: i32, total: i32, data: ?[]const u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(seq);
    try w.writeI32(total);
    if (data) |d| {
        try w.writeI32(@intCast(d.len));
        try w.writeBytes(d);
    } else {
        try w.writeI32(-1);
    }
    return w.written();
}

test "localization body carries seq, total and the deflate blob" {
    // NetPackageLocalization::write IL=0030: seqNr i32, totalParts i32,
    // data length (i32, -1 for null) then the bytes.
    var buf: [64]u8 = undefined;
    const body = try buildLocalizationBody(&buf, 0, 1, &[_]u8{ 0x03, 0x00 });
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0, 0, 0, 0, // seqNr
        1, 0, 0, 0, // totalParts
        2,    0,    0, 0, // data length
        0x03, 0x00,
    }, body);
    const nul = try buildLocalizationBody(&buf, 2, 3, null);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        2, 0, 0, 0, 3, 0, 0, 0, 0xff, 0xff, 0xff, 0xff,
    }, nul);
}
