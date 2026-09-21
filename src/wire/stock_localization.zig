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
