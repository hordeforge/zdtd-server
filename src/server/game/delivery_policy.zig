//! S2C delivery classifiers: unreliable, compressed, and droppable packages.
//!
//! Pure name tables with no Game / net imports. Shared by `net.zig` (send path)
//! and `send_extra.zig` (deflate framing) so those modules stay one-way:
//! net → send_extra, never the reverse.

const std = @import("std");

/// Stock EntityPlayer/NetConnectionAbs `get_ReliableDelivery` overrides
/// (asm.il 816202-816208, 793041-793050): these five S2C packages ride the
/// Unreliable delivery method, not the 64-slot reliable window.
pub fn isUnreliablePackage(pkg_name: []const u8) bool {
    const names = [_][]const u8{
        "NetPackageEntityPosAndRot",
        "NetPackageEntityRelPosAndRot",
        "NetPackageEntityRotation",
        "NetPackageEntitySpeeds",
        "NetPackageEntityStatsBuff",
    };
    for (names) |n| {
        if (std.mem.eql(u8, pkg_name, n)) return true;
    }
    return false;
}

/// Stock `get_Compress() == true` (RE network.md: 8 packages, all IL=2). Six
/// zdtd emits are listed; DynamicClientArrive and DynamicMesh stay out (no
/// S2C body builder yet). MapChunks is sent via trySendCompressed from
/// map.zig and must stay in this set so sendGameBudget also deflates it.
pub fn isCompressedPackage(pkg_name: []const u8) bool {
    const names = [_][]const u8{
        "NetPackageChunk",
        "NetPackageSignDataResponse",
        "NetPackageIdMapping",
        "NetPackageConfigFile",
        "NetPackagePOIMetadataResponse",
        "NetPackageMapChunks",
    };
    for (names) |n| {
        if (std.mem.eql(u8, pkg_name, n)) return true;
    }
    return false;
}

pub fn isDroppablePackage(pkg_name: []const u8) bool {
    // Latest-wins / replaceable under WindowFull. EntityStatChanged stays
    // ReliableOrdered (stock get_ReliableDelivery=true) but a newer value
    // supersedes a stalled one, so hard-failing the send only stalls combat
    // UI while the reliable window is full (playtest: n=1 then n=100 drops).
    const names = [_][]const u8{
        "NetPackageChunk",
        "NetPackageDecoResetWorldChunk",
        "NetPackageEntityPosAndRot",
        "NetPackageEntitySpeeds",
        "NetPackageEntityStatChanged",
        "NetPackageVehiclePositions",
        "NetPackageWorldTime",
        // SignDataResponse rides the compressed path (isCompressedPackage)
        // and its MIDDLE batches go out through plain sendGame. A full window
        // there used to hard-error out of sendSignDataBatches, so the loop
        // never reached the final batch and the client sat on "Starting Game"
        // (blocks worldInfoCo until isLastBatch=true). Dropping a middle batch
        // loses that batch's signs; the final batch is critical and still
        // must deliver.
        "NetPackageSignDataResponse",
    };
    for (names) |n| {
        if (std.mem.eql(u8, pkg_name, n)) return true;
    }
    return false;
}

/// Reliable-window attempt cap for one send. The chunk stream is the only
/// caller allowed a long ladder (a 40 KB chunk fragments against the 64-slot
/// window, so one pass needs far more attempts than a single datagram);
/// droppable packages give up early because a newer value supersedes them.
/// Shared by net.zig and send_extra.zig so the two retry entry points cannot
/// drift apart.
pub fn maxAttemptsFor(pkg_name: []const u8, droppable: bool) u32 {
    if (std.mem.eql(u8, pkg_name, "NetPackageChunk")) return chunk_max_attempts;
    return if (droppable) droppable_max_attempts else must_deliver_max_attempts;
}

const chunk_max_attempts: u32 = 4000;
const droppable_max_attempts: u32 = 64;
const must_deliver_max_attempts: u32 = 960;

test "the attempt ladder is one table for both send entry points" {
    try std.testing.expectEqual(chunk_max_attempts, maxAttemptsFor("NetPackageChunk", true));
    try std.testing.expectEqual(chunk_max_attempts, maxAttemptsFor("NetPackageChunk", false));
    try std.testing.expectEqual(droppable_max_attempts, maxAttemptsFor("NetPackageWorldTime", true));
    try std.testing.expectEqual(must_deliver_max_attempts, maxAttemptsFor("NetPackageWorldInfo", false));
}
