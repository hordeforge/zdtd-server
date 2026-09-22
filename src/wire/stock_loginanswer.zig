//! Login-answer body: bAllowed + data + null lobby/identity pairs.
//!
//! Split out of the packages.zig facade (same builder, moved
//! verbatim); import via `packages.stock_loginanswer` like the other
//! stock_* leaves.

const binary = @import("binary.zig");

/// NetPackagePlayerLoginAnswer (RE inventories/netpackage-bodies.md, write
/// IL=46): `bAllowed` bool | `data` string | `platformLobbyId`
/// (PlatformLobbyId.Write) | host identity (ToStream + string) | server
/// identity (ToStream + string). zdtd writes the lobby and both identity pairs
/// as null: a headless EAC-off dedi has no platform lobby and no host token, so
/// a fabricated identity is exactly what rule 3 forbids. A null
/// PlatformUserIdentifier is one 0 byte, which is the stock null path.
pub fn buildLoginAnswerBody(buf: []u8, allowed: bool, data: []const u8) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeBool(allowed);
    try w.writeString(data);
    try w.writeByte(0); // lobby
    try w.writeByte(0); // platform null
    try w.writeString("");
    try w.writeByte(0);
    try w.writeString("");
    return w.written();
}
