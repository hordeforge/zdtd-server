//! POI metadata bodies: the DynamicPrefabDecorator record and the
//! capped response builder, with the fit test.
//!
//! Split out of the packages.zig facade (same code, same test);
//! import via `packages.stock_poi` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// Stock `PrefabInstance.POIMetadata` record (read ctor IL=35, changelog-3.2.0
/// §3.2): the minimal per-POI metadata the client's DynamicPrefabDecorator
/// consumes for LOD/trader rendering.
pub const PoiMetadata = struct {
    x: i32,
    y: i32,
    z: i32,
    size_x: i32,
    size_y: i32,
    size_z: i32,
    rotation: u8,
    tier: u8,
    trader_area: bool,
    prefab_name: []const u8,
    tags: []const u8,
    quest_tags: []const u8,
};

/// Cap on POI metadata records per response (a stock map ships a few hundred
/// POIs; the frame stays well inside the compressed budget).
pub const max_poi_metadata: usize = 512;

/// NetPackagePOIMetadataResponse body: count:i32 + POIMetadata records
/// (compressed on the wire, channel 1).
pub fn buildPoiMetadataResponse(buf: []u8, records: []const PoiMetadata) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(@intCast(@min(records.len, max_poi_metadata)));
    const n = @min(records.len, max_poi_metadata);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = records[i];
        try w.writeI32(r.x);
        try w.writeI32(r.y);
        try w.writeI32(r.z);
        try w.writeI32(r.size_x);
        try w.writeI32(r.size_y);
        try w.writeI32(r.size_z);
        try w.writeByte(r.rotation);
        try w.writeByte(r.tier);
        try w.writeBool(r.trader_area);
        try w.writeString(r.prefab_name);
        try w.writeString(r.tags);
        try w.writeString(r.quest_tags);
    }
    return w.written();
}

test "POI metadata response: 512 dense records fit the response buffer" {
    // Regression (2026-08-29 Pregen soak): the handler built into a 64 KiB
    // slice, and 512 records with real prefab names/tags exceed it, so the
    // response silently never shipped on dense maps. The handler now uses a
    // 256 KiB slice; this pins that the worst-case record count fits.
    var records: [max_poi_metadata]PoiMetadata = undefined;
    for (&records, 0..) |*r, i| {
        r.* = .{
            .x = @intCast(i),
            .y = 0,
            .z = 0,
            .size_x = 10,
            .size_y = 8,
            .size_z = 10,
            .rotation = 0,
            .tier = 3,
            .trader_area = false,
            .prefab_name = "house_old_brick_02_police_station_red_wasteland_abandoned",
            .tags = "wasteland,house,red,day,residential,abandoned,police",
            .quest_tags = "town,residential,abandoned,police,crime,disturbance",
        };
    }
    var buf: [262144]u8 = undefined;
    const body = try buildPoiMetadataResponse(&buf, &records);
    try std.testing.expect(body.len > 65536); // the old slice could not hold it
    try std.testing.expect(body.len < buf.len);

    // Size alone says nothing about field order, and the record above cannot
    // say it either: y, z and rotation all sit at 0. Build one record with a
    // distinct value everywhere and read it back - the client keys map markers
    // and quest offers off these, so a rotated triple misplaces a POI.
    const one = [_]PoiMetadata{.{
        .x = 11,
        .y = 12,
        .z = 13,
        .size_x = 21,
        .size_y = 22,
        .size_z = 23,
        .rotation = 2,
        .tier = 5,
        .trader_area = true,
        .prefab_name = "p",
        .tags = "t",
        .quest_tags = "q",
    }};
    var one_buf: [512]u8 = undefined;
    const b = try buildPoiMetadataResponse(&one_buf, &one);
    try std.testing.expectEqual(@as(i32, 1), std.mem.readInt(i32, b[0..4], .little)); // count
    try std.testing.expectEqual(@as(i32, 11), std.mem.readInt(i32, b[4..8], .little));
    try std.testing.expectEqual(@as(i32, 12), std.mem.readInt(i32, b[8..12], .little));
    try std.testing.expectEqual(@as(i32, 13), std.mem.readInt(i32, b[12..16], .little));
    try std.testing.expectEqual(@as(i32, 21), std.mem.readInt(i32, b[16..20], .little));
    try std.testing.expectEqual(@as(i32, 22), std.mem.readInt(i32, b[20..24], .little));
    try std.testing.expectEqual(@as(i32, 23), std.mem.readInt(i32, b[24..28], .little));
    try std.testing.expectEqual(@as(u8, 2), b[28]); // rotation
    try std.testing.expectEqual(@as(u8, 5), b[29]); // tier
    try std.testing.expectEqual(@as(u8, 1), b[30]); // traderArea
}
