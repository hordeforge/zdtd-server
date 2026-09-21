//! World-areas bodies: trader compound entries with teleport volumes
//! and the WorldAreas builder, with the layout test.
//!
//! Split out of the packages.zig facade (same code, same test);
//! import via `packages.stock_areas` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// One trader compound for NetPackageWorldAreas: position/size/protect
/// padding plus the prefab's teleport volumes (local cells).
pub const TraderTeleport = struct {
    start_x: i8 = 0,
    start_y: i8 = 0,
    start_z: i8 = 0,
    size_x: u8 = 0,
    size_y: u8 = 0,
    size_z: u8 = 0,
};

pub const TraderAreaEntry = struct {
    pos_x: i32 = 0,
    pos_y: i32 = 0,
    pos_z: i32 = 0,
    size_x: i16 = 0,
    size_y: i16 = 0,
    size_z: i16 = 0,
    /// GetProtectPadding: (TraderAreaProtect - 2) in x/z, y unchanged.
    pad_x: i8 = 0,
    pad_y: i8 = 0,
    pad_z: i8 = 0,
    teleports: []const TraderTeleport = &.{},
};

/// NetPackageWorldAreas body: byte cVersion=1, i16 count, TraderArea.Write
/// each (Position i32x3, PrefabSize i16x3, GetProtectPadding s8x3, teleport
/// volumes u8 count + startPos s8x3 / size u8x3). Layout from
/// NetPackageWorldAreas::write IL=31 and TraderArea::Write IL=111
/// (../7dtd-engine-research il dump, docs/loot-economy.md:435).
pub fn buildWorldAreasBody(buf: []u8, areas: []const TraderAreaEntry) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeByte(1); // cVersion
    try w.writeI16(@intCast(areas.len));
    for (areas) |a| {
        try w.writeI32(a.pos_x);
        try w.writeI32(a.pos_y);
        try w.writeI32(a.pos_z);
        try w.writeI16(a.size_x);
        try w.writeI16(a.size_y);
        try w.writeI16(a.size_z);
        try w.writeByte(@bitCast(a.pad_x));
        try w.writeByte(@bitCast(a.pad_y));
        try w.writeByte(@bitCast(a.pad_z));
        try w.writeByte(@intCast(a.teleports.len));
        for (a.teleports) |t| {
            try w.writeByte(@bitCast(t.start_x));
            try w.writeByte(@bitCast(t.start_y));
            try w.writeByte(@bitCast(t.start_z));
            try w.writeByte(t.size_x);
            try w.writeByte(t.size_y);
            try w.writeByte(t.size_z);
        }
    }
    return w.written();
}

test "world areas stock wire" {
    var buf: [256]u8 = undefined;
    const body = try buildWorldAreasBody(&buf, &[_]TraderAreaEntry{
        .{
            .pos_x = 10,
            .pos_y = 61,
            .pos_z = 20,
            // size_x and size_z were both 60, which made that swap emit
            // identical bytes; the audit reported it as a survivor.
            .size_x = 60,
            .size_y = 28,
            .size_z = 62,
            // pad_x and pad_z were both -2, which made that swap emit
            // identical bytes.
            .pad_x = -2,
            .pad_y = 0,
            .pad_z = -3,
            .teleports = &.{
                .{ .start_x = 7, .start_y = 1, .start_z = 2, .size_x = 52, .size_y = 12, .size_z = 5 },
                .{ .start_x = 2, .start_y = 1, .start_z = 7, .size_x = 57, .size_y = 28, .size_z = 41 },
            },
        },
    });
    // 1 + 2 + (12 + 6 + 3 + 1 + 2*6)
    try std.testing.expectEqual(@as(usize, 1 + 2 + 34), body.len);
    try std.testing.expectEqual(@as(u8, 1), body[0]); // cVersion
    try std.testing.expectEqual(@as(i16, 1), std.mem.readInt(i16, body[1..3], .little));
    // Whole position and size triples: only pos_x and size_x were read, so
    // pos_y/pos_z and size_y/size_z could swap unnoticed.
    try std.testing.expectEqual(@as(i32, 10), std.mem.readInt(i32, body[3..7], .little));
    try std.testing.expectEqual(@as(i32, 61), std.mem.readInt(i32, body[7..11], .little));
    try std.testing.expectEqual(@as(i32, 20), std.mem.readInt(i32, body[11..15], .little));
    try std.testing.expectEqual(@as(i16, 60), std.mem.readInt(i16, body[15..17], .little));
    try std.testing.expectEqual(@as(i16, 28), std.mem.readInt(i16, body[17..19], .little));
    try std.testing.expectEqual(@as(i16, 62), std.mem.readInt(i16, body[19..21], .little));
    // The padding triple and both teleport triples, not just their first
    // component: pad_y/pad_z, start_y/start_z and size_y/size_z each had
    // nothing reading them back and could swap unnoticed.
    try std.testing.expectEqual(@as(i8, -2), @as(i8, @bitCast(body[21]))); // pad_x
    try std.testing.expectEqual(@as(i8, 0), @as(i8, @bitCast(body[22]))); // pad_y
    try std.testing.expectEqual(@as(i8, -3), @as(i8, @bitCast(body[23]))); // pad_z
    try std.testing.expectEqual(@as(u8, 2), body[24]); // teleport count
    try std.testing.expectEqual(@as(i8, 7), @as(i8, @bitCast(body[25]))); // vol0 start_x
    try std.testing.expectEqual(@as(i8, 1), @as(i8, @bitCast(body[26]))); // vol0 start_y
    try std.testing.expectEqual(@as(i8, 2), @as(i8, @bitCast(body[27]))); // vol0 start_z
    try std.testing.expectEqual(@as(u8, 52), body[28]); // vol0 size_x
    try std.testing.expectEqual(@as(u8, 12), body[29]); // vol0 size_y
    try std.testing.expectEqual(@as(u8, 5), body[30]); // vol0 size_z
    // Second volume follows immediately, six bytes on.
    try std.testing.expectEqual(@as(i8, 2), @as(i8, @bitCast(body[31]))); // vol1 start_x
    try std.testing.expectEqual(@as(i8, 1), @as(i8, @bitCast(body[32])));
    try std.testing.expectEqual(@as(i8, 7), @as(i8, @bitCast(body[33])));
    try std.testing.expectEqual(@as(u8, 57), body[34]); // vol1 size_x
    try std.testing.expectEqual(@as(u8, 28), body[35]);
    try std.testing.expectEqual(@as(u8, 41), body[36]);
}
