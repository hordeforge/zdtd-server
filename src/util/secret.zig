//! Secret comparison helpers shared by every credential check (LiteNet
//! connect key, webui secret, telnet admin password).
//!
//! std.crypto.timing_safe.eql only takes equal-length arrays with a
//! comptime-known length, so it cannot compare the variable-length slices that
//! arrive off the wire. This is the one comparator for that job.

const std = @import("std");

/// Constant-time content compare for untrusted input against a secret.
///
/// Always walks max(a.len, b.len) so remote timing primarily reflects payload
/// size, not an early length branch. Neither slice is retained.
pub fn constantTimeEql(a: []const u8, b: []const u8) bool {
    var diff: u8 = @intFromBool(a.len != b.len);
    const n = @max(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const x: u8 = if (i < a.len) a[i] else 0;
        const y: u8 = if (i < b.len) b[i] else 0;
        diff |= x ^ y;
    }
    return diff == 0;
}

test "constantTimeEql matches only on identical content" {
    try std.testing.expect(constantTimeEql("", ""));
    try std.testing.expect(constantTimeEql("hunter2", "hunter2"));
    try std.testing.expect(!constantTimeEql("hunter2", "hunter3"));
    // Length mismatch, including prefix and empty cases.
    try std.testing.expect(!constantTimeEql("hunter", "hunter2"));
    try std.testing.expect(!constantTimeEql("hunter2", "hunter"));
    try std.testing.expect(!constantTimeEql("", "x"));
    try std.testing.expect(!constantTimeEql("x", ""));
    // Trailing bytes past the shorter slice must not compare as zero padding.
    try std.testing.expect(!constantTimeEql("a\x00", "a"));
}
