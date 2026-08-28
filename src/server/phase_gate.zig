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

/// Packages legal before PlayerLogin is accepted (connecting). A peer that
/// never logs in must not be able to reach the enter/spawn handlers and get a
/// join bundle without an identity (AGENTS rule 18: gate matches the SM state).
const connecting_allow: []const []const u8 = &.{
    "NetPackagePlayerLogin",
    "NetPackagePlayerDisconnect",
};

/// Packages legal after login but before the join bundle (joined).
const joined_allow: []const []const u8 = &.{
    "NetPackagePlayerLogin", // re-login mid-session
    "NetPackageRequestToEnterGame",
    "NetPackageRequestToSpawnPlayer",
    "NetPackageAuthConfirmation",
    "NetPackageSignDataRequest",
    "NetPackageWorldInitInfoRequest",
    "NetPackageDynamicClientArrive",
    "NetPackagePOIMetadataRequest", // V3.2.0: the client asks during world creation (DynamicPrefabDecorator)
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
/// handshake packages legal for that join-SM state.
pub fn allowed(phase: Phase, name: []const u8) bool {
    return switch (phase) {
        .connecting => nameIn(connecting_allow, name),
        .joined => nameIn(joined_allow, name),
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
    // Pre-login peers cannot reach the enter/spawn handlers.
    try std.testing.expect(!allowed(.connecting, "NetPackageRequestToEnterGame"));
    try std.testing.expect(!allowed(.connecting, "NetPackageRequestToSpawnPlayer"));
    try std.testing.expect(!allowed(.connecting, "NetPackageDynamicClientArrive"));
    try std.testing.expect(allowed(.joined, "NetPackageRequestToEnterGame"));
    try std.testing.expect(allowed(.joined, "NetPackageRequestToSpawnPlayer"));
    try std.testing.expect(allowed(.joined, "NetPackageDynamicClientArrive"));
    try std.testing.expect(!allowed(.connecting, "NetPackageEntityPosAndRot"));
    try std.testing.expect(!allowed(.joined, "NetPackageSetBlock"));
    try std.testing.expect(!allowed(.joined, "NetPackageEntityPosAndRot"));
    // Play-world C2S must stay gated until join bundle (playing).
    try std.testing.expect(!allowed(.connecting, "NetPackageDamageEntity"));
    try std.testing.expect(!allowed(.connecting, "NetPackagePlayerInventory"));
    try std.testing.expect(!allowed(.joined, "NetPackageDamageEntity"));
    try std.testing.expect(!allowed(.joined, "NetPackageTELockRequest"));
    try std.testing.expect(allowed(.playing, "NetPackageEntityPosAndRot"));
    try std.testing.expect(allowed(.playing, "NetPackageSetBlock"));
    try std.testing.expect(allowed(.playing, "NetPackageDamageEntity"));
    try std.testing.expect(allowed(.playing, "NetPackageUnknownFuture"));
}
