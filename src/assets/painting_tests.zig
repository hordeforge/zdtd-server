//! Painting catalog tests: stock load.
//!
//! Split out of assets/painting.zig (same tests, moved verbatim).

const std = @import("std");
const painting = @import("painting.zig");
const loadFromPath = painting.loadFromPath;
const xml = @import("xml_util.zig");
const stock_paths = @import("../util/stock_paths.zig");
const io_fs = @import("../util/io_fs.zig");

test "load painting.xml when present" {
    const p = stock_paths.configFile("painting.xml");
    if (!io_fs.fileExists(p)) return error.SkipZigTest;
    const t = try loadFromPath(std.testing.allocator, p);
    defer {
        var tt = t;
        tt.deinit();
    }
    try std.testing.expect(t.n > 10);
    try std.testing.expectEqual(@as(u16, 0), t.textureOf(0).?);
    try std.testing.expectEqual(@as(u16, 7), t.textureOf(1).?); // brick
}
