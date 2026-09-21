//! Frame helpers: the get_Channel override set, the channelFor
//! selector, and the framed envelope builder, with the channel test.
//!
//! Split out of the packages.zig facade (same code, same test);
//! import via `packages.stock_frame` like the other stock_* leaves.

const std = @import("std");
const frame = @import("frame.zig");
const stock_ids = @import("stock_ids.zig");
const idOf = stock_ids.idOf;
const default_mappings = stock_ids.default_mappings;
const stock_map = @import("stock_map.zig");
const buildChunkBody = stock_map.buildChunkBody;
const chunk_body_size: usize = stock_map.chunk_body_size;
const chunk_stock_envelope_overhead: usize = stock_map.chunk_stock_envelope_overhead;

/// Stock `NetPackage.get_Channel` override set: bulk world data rides envelope
/// channel 1 so it does not sit in the same queue as control traffic.
/// `NetPackage::get_Channel` returns 0 (IL=2) and exactly four packages
/// override it to 1, each `get_Channel() IL=2` returning `ldc.i4.1`:
/// NetPackageChunk, NetPackageChunkRemove, NetPackageDynamicMesh,
/// NetPackageMapChunks and NetPackageWorldFolder (RE network.md "Second
/// envelope stream ... 5 packages";
/// `il/netpackages-v3.2.0/NetPackageWorldFolder_il.txt` IL_0000 = ldc.i4.1).
/// WorldFolder was missing here until 2026-09-06; zdtd never emits it, so
/// nothing was mis-sent, but the channel would have been wrong on the first
/// send.
///
/// `NetPackagePOIMetadataResponse` is deliberately absent. Its 3.1.0
/// predecessor `NetPackagePOIAround` did override to 1
/// (`il/full-v3.1.0/_global/NetPackagePOIAround.il.txt`), but the 3.2.0
/// replacement declares no `get_Channel` at all
/// (`il/full-v3.2.0/_global/NetPackagePOIMetadataResponse.il.txt`, base
/// NetPackage, no intermediate class), so it inherits channel 0. zdtd carried
/// the old channel across the package swap until 2026-09-04.
pub fn channelFor(name: []const u8) u8 {
    if (std.mem.eql(u8, name, "NetPackageChunk") or
        std.mem.eql(u8, name, "NetPackageChunkRemove") or
        std.mem.eql(u8, name, "NetPackageDynamicMesh") or
        std.mem.eql(u8, name, "NetPackageMapChunks") or
        std.mem.eql(u8, name, "NetPackageWorldFolder")) return 1;
    return 0;
}

pub fn framed(buf: []u8, name: []const u8, body: []const u8) ![]u8 {
    const id = idOf(name) orelse return error.UnknownPackage;
    return frame.framePackage(buf, channelFor(name), id, body);
}

test "only the five stock get_Channel overrides ride channel 1" {
    // Nothing tested this: dropping every override to 0 left the suite green.
    // The set is the packages whose `get_Channel() IL=2` returns ldc.i4.1;
    // `NetPackage::get_Channel` returns 0 for everything else.
    //
    // WorldFolder was missing here until 2026-09-06. The RE names five
    // (network.md "Second envelope stream ... 5 packages") and
    // `il/netpackages-v3.2.0/NetPackageWorldFolder_il.txt` IL_0000 is
    // `ldc.i4.1`; the test asserted "four" and so pinned the omission in
    // place. zdtd never emits WorldFolder, so nothing was mis-sent, but the
    // channel would have been wrong the moment it did.
    const on_one = [_][]const u8{
        "NetPackageChunk",
        "NetPackageChunkRemove",
        "NetPackageDynamicMesh",
        "NetPackageMapChunks",
        "NetPackageWorldFolder",
    };
    for (on_one) |n| try std.testing.expectEqual(@as(u8, 1), channelFor(n));

    // Every other advertised package inherits 0. Checking the whole table
    // rather than a sample is what catches a name added to the override set
    // without an IL override behind it - which is how POIMetadataResponse got
    // there, inherited from its removed 3.1.0 predecessor POIAround.
    for (default_mappings) |n| {
        var overridden = false;
        for (on_one) |o| {
            if (std.mem.eql(u8, n, o)) overridden = true;
        }
        if (overridden) continue;
        try std.testing.expectEqual(@as(u8, 0), channelFor(n));
    }
}

test "NetPackageChunk resolves to an id and frames at that id" {
    // The id itself is not a contract: ids are negotiated through
    // NetPackagePackageIds, so the client uses whatever index this table
    // advertises. What must hold is that the name resolves and that `framed`
    // stamps the same id `idOf` returns - a mismatch there would send terrain
    // under a header the client resolves to some other package.
    const chunk_id = idOf("NetPackageChunk") orelse return error.TestUnexpectedResult;
    var heights: [256]u8 = .{70} ** 256;
    var body_buf: [512]u8 = undefined;
    const body = try buildChunkBody(&body_buf, -18, 28, &heights);
    try std.testing.expectEqual(@as(usize, chunk_stock_envelope_overhead + chunk_body_size), body.len);
    var frame_buf: [512]u8 = undefined;
    const fr = try framed(&frame_buf, "NetPackageChunk", body);
    // framePackage: channel 1 | payloadSize i32 | compressed 1 | encrypted 1 |
    // count u16 | contentLen i32, then the package id.
    const pkg_id_off: usize = 1 + 4 + 1 + 1 + 2 + 4;
    try std.testing.expectEqual(chunk_id, std.mem.readInt(u16, fr[pkg_id_off..][0..2], .little));
    // LiteNet channeled total must fit pending_bytes (1200).
    try std.testing.expect(fr.len + 4 < 1200);
}
