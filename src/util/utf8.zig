//! UTF-8 boundary helpers for fixed buffers and display caps.
//!
//! Wire length prefixes and stock .NET strings count UTF-8 *bytes*. When a
//! fixed destination is smaller than the source, cutting mid-sequence leaves
//! invalid UTF-8 that stock BinaryReader and browsers both mis-render. Callers
//! that store or re-broadcast text must keep a whole codepoint.

const std = @import("std");

/// Largest `n <= cap` that keeps `s[0..n]` a whole number of well-formed
/// UTF-8 codepoints. Fixed-size operator surfaces (webui world name, audit
/// lines, owner-name fields) cut long text; a cut between the bytes of one
/// codepoint puts invalid UTF-8 into a UTF-8 response body or a persisted key.
/// A malformed source stops the scan there rather than emitting the bad bytes.
pub fn truncLen(s: []const u8, cap: usize) usize {
    var n: usize = 0;
    while (n < s.len and n < cap) {
        if (s[n] < 0x80) {
            n += 1;
            continue;
        }
        const seq = std.unicode.utf8ByteSequenceLength(s[n]) catch break;
        if (n + seq > cap or n + seq > s.len) break; // would run past the cap or the source
        if (!std.unicode.utf8ValidateSlice(s[n..][0..seq])) break;
        n += seq;
    }
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

test "truncLen drops a malformed source instead of re-emitting it" {
    // A lone high byte, a truncated lead byte and a lone surrogate half all
    // end the prefix; the result is always decodable.
    const cases = [_]struct { src: []const u8, cap: usize, want: usize }{
        .{ .src = "Caf\xE9 Server", .cap = 64, .want = 3 },
        .{ .src = "Caf\xC3", .cap = 64, .want = 3 },
        .{ .src = "A\xED\xA0\x80B", .cap = 64, .want = 1 },
        .{ .src = "ok\xFF", .cap = 2, .want = 2 },
    };
    for (cases) |c| {
        const n = truncLen(c.src, c.cap);
        try std.testing.expect(std.unicode.utf8ValidateSlice(c.src[0..n]));
        try std.testing.expectEqual(c.want, n);
    }
}
