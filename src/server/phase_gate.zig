//! Per-package C2S phase allowlist (join SM × package name).
//! Hot path: string compares against static tables; no heap.

const std = @import("std");

/// Client join progress. Mapped from Client.joined / Client.entered.
pub const Phase = enum(u8) {
    /// Challenge/auth done, PlayerLogin not accepted yet.
    connecting,
    /// Login accepted, join bundle not yet sent (enter/spawn SM).
    joined,
    /// Join bundle sent; world play C2S legal.
    playing,
};

/// Map client flags to phase. `entered` implies mid/post spawn bundle.
pub fn phaseOf(joined: bool, entered: bool) Phase {
    if (!joined) return .connecting;
    if (!entered) return .joined;
    return .playing;
}

/// Handshake / join-SM packages legal before `playing`.
const pre_play_allow: []const []const u8 = &.{
    "NetPackagePlayerLogin",
    "NetPackageRequestToEnterGame",
    "NetPackageRequestToSpawnPlayer",
    "NetPackageAuthConfirmation",
    "NetPackageSignDataRequest",
    "NetPackageWorldInitInfoRequest",
    "NetPackageDynamicClientArrive",
    "NetPackagePlayerDisconnect",
};

fn nameIn(list: []const []const u8, name: []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// True when `name` may be handled in `phase`. Playing allows all C2S names
/// (typed handlers still validate ownership/bounds). Earlier phases only the
/// join-SM allowlist.
pub fn allowed(phase: Phase, name: []const u8) bool {
    return switch (phase) {
        .connecting, .joined => nameIn(pre_play_allow, name),
        .playing => true,
    };
}

test "phaseOf mapping" {
    try std.testing.expectEqual(Phase.connecting, phaseOf(false, false));
    try std.testing.expectEqual(Phase.connecting, phaseOf(false, true));
    try std.testing.expectEqual(Phase.joined, phaseOf(true, false));
    try std.testing.expectEqual(Phase.playing, phaseOf(true, true));
}

test "phase allow deny" {
    try std.testing.expect(allowed(.connecting, "NetPackagePlayerLogin"));
    try std.testing.expect(allowed(.connecting, "NetPackageRequestToEnterGame"));
    try std.testing.expect(allowed(.joined, "NetPackageRequestToSpawnPlayer"));
    try std.testing.expect(allowed(.joined, "NetPackageDynamicClientArrive"));
    try std.testing.expect(!allowed(.connecting, "NetPackageEntityPosAndRot"));
    try std.testing.expect(!allowed(.joined, "NetPackageSetBlock"));
    try std.testing.expect(!allowed(.joined, "NetPackageEntityPosAndRot"));
    try std.testing.expect(allowed(.playing, "NetPackageEntityPosAndRot"));
    try std.testing.expect(allowed(.playing, "NetPackageSetBlock"));
    try std.testing.expect(allowed(.playing, "NetPackageUnknownFuture"));
}
