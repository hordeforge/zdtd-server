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
    // A stock-unreliable package has no retransmit on the wire at all, so it is
    // droppable by construction. It only reaches this classifier at all when
    // the framed message exceeds the peer's negotiated MTU and net.zig falls
    // through to the reliable window: without this arm an oversized
    // EntityStatsBuff (a full 1024 B buff blob against a 1024 B MtuCheck) got
    // the must-deliver attempt ladder and a hard error.WindowFull, which aborts
    // sendBuffSync mid-join instead of skipping one replaceable update.
    if (isUnreliablePackage(pkg_name)) return true;
    // Latest-wins / replaceable under WindowFull. EntityStatChanged stays
    // ReliableOrdered (stock get_ReliableDelivery=true) but a newer value
    // supersedes a stalled one, so hard-failing the send only stalls combat
    // UI while the reliable window is full (playtest: n=1 then n=100 drops).
    const names = [_][]const u8{
        "NetPackageChunk",
        "NetPackageDecoResetWorldChunk",
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

// zdtd send-retry policy, not stock wire: how many reliable-window passes one
// S2C send may occupy before net.zig gives up on it. Scaled off the 64-slot
// LiteNet reliable window (litenet/packet.zig window_size).
//
// A 40 KB chunk fragments well past one window, so the chunk stream needs a
// ladder orders of magnitude longer than a single datagram.
const chunk_max_attempts: u32 = 4000;
// One window's worth: a droppable package is superseded by the next value, so
// retrying past the current window only delays fresher state.
const droppable_max_attempts: u32 = 64;
// Fifteen windows: enough for a must-deliver package to survive a burst of
// loss without pinning a slot for the length of a chunk transfer.
const must_deliver_max_attempts: u32 = 960;

/// Reliable-window attempt cap for one send. Shared by net.zig and
/// send_extra.zig so the two retry entry points cannot drift apart.
pub fn maxAttemptsFor(pkg_name: []const u8, droppable: bool) u32 {
    if (std.mem.eql(u8, pkg_name, "NetPackageChunk")) return chunk_max_attempts;
    return if (droppable) droppable_max_attempts else must_deliver_max_attempts;
}

test "every unreliable package is droppable on the MTU fallthrough" {
    // net.zig only reaches the reliable window for an unreliable package when
    // the frame is larger than the peer's negotiated MTU. Classifying one of
    // them as must-deliver there burns the 960-attempt ladder on the tick and
    // returns error.WindowFull to a caller (sendBuffSync) that aborts a join
    // bundle over a replaceable update.
    const unreliable = [_][]const u8{
        "NetPackageEntityPosAndRot",
        "NetPackageEntityRelPosAndRot",
        "NetPackageEntityRotation",
        "NetPackageEntitySpeeds",
        "NetPackageEntityStatsBuff",
    };
    for (unreliable) |n| {
        try std.testing.expect(isUnreliablePackage(n));
        try std.testing.expect(isDroppablePackage(n));
        try std.testing.expectEqual(droppable_max_attempts, maxAttemptsFor(n, isDroppablePackage(n)));
    }
}

test "the attempt ladder is one table for both send entry points" {
    try std.testing.expectEqual(chunk_max_attempts, maxAttemptsFor("NetPackageChunk", true));
    try std.testing.expectEqual(chunk_max_attempts, maxAttemptsFor("NetPackageChunk", false));
    try std.testing.expectEqual(droppable_max_attempts, maxAttemptsFor("NetPackageWorldTime", true));
    try std.testing.expectEqual(must_deliver_max_attempts, maxAttemptsFor("NetPackageWorldInfo", false));
}
