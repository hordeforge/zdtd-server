//! Wire constants from research/docs/protocol.md (V3.x loadgen golden; wire pin V3.1.0).
//! Package IDs are dynamic (PackageIds map); never hard-code across builds.
//!
//! Leaf module at src root (shared by wire/frame, server tick, main CLI). Also
//! re-exported as `wire.protocol` via wire/root.zig for package discovery.

const std = @import("std");

/// Pre-auth challenge: raw [0xCA][Guid16]
pub const challenge_marker: u8 = 0xCA;
pub const challenge_size: usize = 17;

/// LiteNet reserved header: channel byte
pub const reserved_header_bytes: usize = 1;
/// Outer envelope after channel: size(4)+comp(1)+enc(1)+count(2)
pub const outer_envelope_after_channel: usize = 8;

/// Stock GameTimer target (research closed-gaps / loop)
pub const ticks_per_second: u32 = 20;
pub const tick_ns: u64 = 1_000_000_000 / ticks_per_second;

/// Golden body sizes (loadgen PackageCodec; excludes pkgId)
pub const body_entity_pos_and_rot_no_q: usize = 30;
pub const body_entity_rel_pos_and_rot_no_q: usize = 20;
pub const body_entity_alive_flags: usize = 6;

/// contentLen = pkgId(2) + body for RelPos !q
pub const content_len_entity_rel_pos_and_rot_no_q: usize = 22;

pub fn challengeEchoValid(packet: []const u8) bool {
    return packet.len == challenge_size and packet[0] == challenge_marker;
}

test "challengeEchoValid" {
    var pkt: [17]u8 = .{0} ** 17;
    pkt[0] = challenge_marker;
    try std.testing.expect(challengeEchoValid(&pkt));
    pkt[0] = 0;
    try std.testing.expect(!challengeEchoValid(&pkt));
}
