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
