//! UTF-8 boundary helpers for fixed buffers and display caps.
//!
//! Wire length prefixes and stock .NET strings count UTF-8 *bytes*. When a
//! fixed destination is smaller than the source, cutting mid-sequence leaves
//! invalid UTF-8 that stock BinaryReader and browsers both mis-render. Callers
//! that store or re-broadcast text must keep a whole codepoint.

const std = @import("std");

/// Largest `n <= cap` that keeps `s[0..n]` from ending inside a UTF-8 sequence.
/// Fixed-size operator surfaces (webui world name, audit lines, owner-name
/// fields) cut long text; a cut between the bytes of one codepoint puts
/// invalid UTF-8 into a UTF-8 response body or a persisted key.
pub fn truncLen(s: []const u8, cap: usize) usize {
    if (s.len <= cap) return s.len;
    var n = cap;
    while (n > 0 and s[n] & 0xc0 == 0x80) n -= 1; // step back over continuation bytes
    return n;
}

test "truncLen never cuts inside a codepoint" {
    try std.testing.expectEqual(@as(usize, 3), truncLen("abc", 8));
    try std.testing.expectEqual(@as(usize, 2), truncLen("abc", 2));
    // "日本" is 3 bytes per codepoint: caps 3..5 keep exactly one.
    try std.testing.expectEqual(@as(usize, 3), truncLen("日本", 5));
    try std.testing.expectEqual(@as(usize, 3), truncLen("日本", 3));
    try std.testing.expectEqual(@as(usize, 0), truncLen("日本", 2));
    try std.testing.expectEqual(@as(usize, 6), truncLen("日本", 6));
    // Astral plane (4-byte rocket): a 3-byte cap keeps nothing.
    try std.testing.expectEqual(@as(usize, 0), truncLen("\u{1f680}", 3));
    try std.testing.expectEqual(@as(usize, 4), truncLen("\u{1f680}", 4));
}
