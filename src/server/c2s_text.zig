//! C2S text trust boundary: player names, chat bodies, player console verbs.
//! Pure helpers (no Game / net types). Extracted from game.zig for navigability.

const std = @import("std");
const utf8_util = @import("../util/utf8.zig");

/// Max UTF-8 bytes in a player Global chat message (stock UI is short; caps flood payload).
pub const max_chat_msg_len: usize = 256;

/// Re-export: fixed buffers and display caps cut on a codepoint boundary.
pub const utf8TruncLen = utf8_util.truncLen;

/// True when `s` equals any of the given alternatives (console verb aliases).
pub fn eqAny(s: []const u8, alts: []const []const u8) bool {
    for (alts) |a| if (std.mem.eql(u8, s, a)) return true;
    return false;
}

/// Copy `src` into `dst`, dropping C0 controls, DEL, and invalid UTF-8 byte
/// sequences, and never splitting a codepoint at the destination cap. Returns
/// written length. The name is re-broadcast to every peer and persisted, so the
/// result must stay valid UTF-8: a byte split inside a multi-byte sequence
/// would desync what stock .NET clients decode from the name field.
pub fn sanitizePlayerName(dst: []u8, src: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(src[i]) catch {
            i += 1; // not a lead byte: skip the garbage byte
            continue;
        };
        if (i + cp_len > src.len or !std.unicode.utf8ValidateSlice(src[i..][0..cp_len])) {
            i += 1; // truncated, overlong, surrogate, or out-of-range: skip one byte
            continue;
        }
        if (src[i] < 0x20 or src[i] == 0x7f) {
            i += cp_len; // C0 control / DEL (multi-byte leads are >= 0xC0): drop, keep scanning
            continue;
        }
        // Format / invisible codepoints that pad or reorder identity text:
        // - Bidi embeddings/overrides/isolates (U+202A-202E, U+2066-2069)
        //   rewrite the rest of an operator line (kick/ban, webui table).
        // - Zero-width space / word joiner / BOM / soft hyphen let two peers
        //   look identical while comparing unequal for reclaim/ban-by-name
        //   (e.g. "Admin" vs "Admin\u{200b}").
        // LRM/RLM/ALM and ZWJ (emoji sequences) are kept as content.
        if (std.unicode.utf8Decode(src[i..][0..cp_len])) |cp| {
            if ((cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2066 and cp <= 0x2069) or
                cp == 0x00AD or cp == 0x200B or cp == 0x2060 or cp == 0xFEFF)
            {
                i += cp_len;
                continue;
            }
        } else |_| {
            i += 1; // unreachable after validation; drop the byte rather than trust it
            continue;
        }
        if (w + cp_len > dst.len) break; // cap: stop before splitting a codepoint
        // In-place callers pass dst == src (c.name sanitized from login.name):
        // forward copy with w <= i can overlap by < 1 codepoint, so memmove.
        @memmove(dst[w..][0..cp_len], src[i..][0..cp_len]);
        w += cp_len;
        i += cp_len;
    }
    return w;
}

/// Global chat body bounds: non-empty, length-capped, no C0/DEL (log/UI
/// injection), valid UTF-8. The body is re-broadcast verbatim to every peer, so
/// malformed sequences must not reach the wire (stock clients decode with
/// replacement; we fail closed instead).
pub fn chatMsgOk(msg: []const u8) bool {
    if (msg.len == 0 or msg.len > max_chat_msg_len) return false;
    for (msg) |ch| {
        if (ch < 0x20 or ch == 0x7f) return false;
    }
    return std.unicode.utf8ValidateSlice(msg);
}

/// Commands accepted from an ordinary player's F1 console. Administrative and
/// world-mutating commands are available only through the loopback admin TCP
/// console, which is a separate trust boundary. The list is the single source
/// of truth: `isPlayerConsoleCommand` matches against it, and the admin
/// console's cross-check test (player_console_help) asserts the in-game help
/// shows exactly these verbs.
pub const player_console_allowlist = [_][]const u8{
    "help",        "commands",  "?",             "gettime", "gt",      "listplayers", "lp",
    "listents",    "le",        "say",           "s",       "version", "dm",          "cm",
    "settempunit", "debugmenu", "listplayerids", "lpi",
};

pub fn isPlayerConsoleCommandAllowlist() []const []const u8 {
    return &player_console_allowlist;
}

pub fn isPlayerConsoleCommand(verb: []const u8) bool {
    return eqAny(verb, &player_console_allowlist);
}

test "player console policy rejects administrative mutations" {
    try std.testing.expect(isPlayerConsoleCommand("help"));
    try std.testing.expect(isPlayerConsoleCommand("gettime"));
    try std.testing.expect(isPlayerConsoleCommand("say"));
    try std.testing.expect(!isPlayerConsoleCommand("settime"));
    try std.testing.expect(!isPlayerConsoleCommand("giveself"));
    try std.testing.expect(!isPlayerConsoleCommand("spawnentity"));
    try std.testing.expect(!isPlayerConsoleCommand("killall"));
    try std.testing.expect(!isPlayerConsoleCommand("kick"));
    try std.testing.expect(!isPlayerConsoleCommand("ban"));
}

test "player console allows only the read-only stock additions" {
    try std.testing.expect(isPlayerConsoleCommand("listplayerids"));
    try std.testing.expect(isPlayerConsoleCommand("lpi"));
    // Every mutating or permission-bearing stock verb stays admin-console-only.
    try std.testing.expect(!isPlayerConsoleCommand("admin"));
    try std.testing.expect(!isPlayerConsoleCommand("whitelist"));
    try std.testing.expect(!isPlayerConsoleCommand("kickall"));
    try std.testing.expect(!isPlayerConsoleCommand("setgamepref"));
    try std.testing.expect(!isPlayerConsoleCommand("sg"));
    try std.testing.expect(!isPlayerConsoleCommand("getgamepref"));
    try std.testing.expect(!isPlayerConsoleCommand("gg"));
    try std.testing.expect(!isPlayerConsoleCommand("mem"));
    try std.testing.expect(!isPlayerConsoleCommand("chunkcache"));
    try std.testing.expect(!isPlayerConsoleCommand("cc"));
    try std.testing.expect(!isPlayerConsoleCommand("shutdown"));
}

test "sanitizePlayerName drops control characters" {
    var buf: [32]u8 = undefined;
    const n = sanitizePlayerName(&buf, "Al\nice\x7f");
    try std.testing.expectEqualStrings("Alice", buf[0..n]);
    try std.testing.expectEqual(@as(usize, 0), sanitizePlayerName(&buf, "\r\n\t"));
    // Destination cap: stop writing once full (no overflow past dst.len).
    var tiny: [3]u8 = undefined;
    const nt = sanitizePlayerName(&tiny, "ABCDEF");
    try std.testing.expectEqual(@as(usize, 3), nt);
    try std.testing.expectEqualStrings("ABC", tiny[0..nt]);
}

test "sanitizePlayerName never splits a UTF-8 codepoint at the cap" {
    // 17 x "é" (2 bytes each) = 34 bytes; the 16-byte-aligned cap must stop at
    // a codepoint boundary, not leave a dangling continuation byte.
    var buf: [32]u8 = undefined;
    const n = sanitizePlayerName(&buf, "é" ** 17);
    try std.testing.expectEqual(@as(usize, 32), n);
    try std.testing.expectEqualStrings("é" ** 16, buf[0..n]);
    // CJK: 3-byte codepoints; a 4-byte cap keeps exactly one full codepoint.
    var tiny: [4]u8 = undefined;
    const nt = sanitizePlayerName(&tiny, "名前");
    try std.testing.expectEqual(@as(usize, 3), nt);
    try std.testing.expectEqualStrings("名", tiny[0..nt]);
}

test "sanitizePlayerName drops invalid UTF-8 sequences" {
    var buf: [32]u8 = undefined;
    // Stray continuation byte, truncated lead, overlong encoding, and a
    // UTF-16 surrogate half (ED A0 80) are all rejected, not copied.
    const n = sanitizePlayerName(&buf, "A\xFFB\xC3\xC0\xAF\xED\xA0\x80C");
    try std.testing.expectEqualStrings("ABC", buf[0..n]);
    // Valid non-ASCII content still passes through untouched.
    const n2 = sanitizePlayerName(&buf, "Émile-海");
    try std.testing.expectEqualStrings("Émile-海", buf[0..n2]);
}

test "sanitizePlayerName drops bidi overrides but keeps RTL content" {
    var buf: [32]u8 = undefined;
    // U+202E RLO then U+2069 PDI: both dropped, the visible text survives.
    const n = sanitizePlayerName(&buf, "adm\u{202e}nimda\u{2069}");
    try std.testing.expectEqualStrings("admnimda", buf[0..n]);
    // Arabic name with an RLM mark stays byte-identical.
    const n2 = sanitizePlayerName(&buf, "\u{200f}محمد");
    try std.testing.expectEqualStrings("\u{200f}محمد", buf[0..n2]);
}

test "sanitizePlayerName drops zero-width padding used as a second identity" {
    var buf: [32]u8 = undefined;
    // U+200B ZWSP between letters: looks like "Admin" but was a distinct key.
    const n = sanitizePlayerName(&buf, "Ad\u{200b}min\u{feff}");
    try std.testing.expectEqualStrings("Admin", buf[0..n]);
    // Soft hyphen and word joiner likewise.
    const n2 = sanitizePlayerName(&buf, "Bo\u{00ad}t\u{2060}");
    try std.testing.expectEqualStrings("Bot", buf[0..n2]);
    // ZWJ in an emoji ZWJ sequence is kept (not padding).
    const n3 = sanitizePlayerName(&buf, "A\u{200d}B");
    try std.testing.expectEqualStrings("A\u{200d}B", buf[0..n3]);
}

test "utf8TruncLen never cuts inside a codepoint" {
    try std.testing.expectEqual(@as(usize, 3), utf8TruncLen("abc", 8));
    try std.testing.expectEqual(@as(usize, 2), utf8TruncLen("abc", 2));
    try std.testing.expectEqual(@as(usize, 3), utf8TruncLen("日本", 5));
    try std.testing.expectEqual(@as(usize, 0), utf8TruncLen("\u{1f680}", 3));
}

test "chatMsgOk length and control bounds" {
    try std.testing.expect(chatMsgOk("hello"));
    try std.testing.expect(!chatMsgOk(""));
    try std.testing.expect(!chatMsgOk("bad\nline"));
    try std.testing.expect(!chatMsgOk("x" ** (max_chat_msg_len + 1)));
    try std.testing.expect(chatMsgOk("x" ** max_chat_msg_len));
    try std.testing.expect(!chatMsgOk("del\x7f"));
}

test "chatMsgOk rejects malformed UTF-8 before broadcast" {
    try std.testing.expect(chatMsgOk("héllo 海"));
    try std.testing.expect(!chatMsgOk("bad\xFFbyte"));
    try std.testing.expect(!chatMsgOk("trunc\xC3"));
    try std.testing.expect(!chatMsgOk("\xED\xA0\x80surrogate"));
}
