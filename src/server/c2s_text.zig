//! C2S text trust boundary: player names, chat bodies, player console verbs.
//! Pure helpers (no Game / net types). Extracted from game.zig for navigability.

const std = @import("std");

/// Max UTF-8 bytes in a player Global chat message (stock UI is short; caps flood payload).
pub const max_chat_msg_len: usize = 256;

/// True when `s` equals any of the given alternatives (console verb aliases).
pub fn eqAny(s: []const u8, alts: []const []const u8) bool {
    for (alts) |a| if (std.mem.eql(u8, s, a)) return true;
    return false;
}

/// Copy `src` into `dst`, dropping C0 controls and DEL. Returns written length.
pub fn sanitizePlayerName(dst: []u8, src: []const u8) usize {
    var w: usize = 0;
    for (src) |ch| {
        if (w >= dst.len) break;
        if (ch < 0x20 or ch == 0x7f) continue;
        dst[w] = ch;
        w += 1;
    }
    return w;
}

/// Global chat body bounds: non-empty, length-capped, no C0/DEL (log/UI injection).
pub fn chatMsgOk(msg: []const u8) bool {
    if (msg.len == 0 or msg.len > max_chat_msg_len) return false;
    for (msg) |ch| {
        if (ch < 0x20 or ch == 0x7f) return false;
    }
    return true;
}

/// Commands accepted from an ordinary player's F1 console. Administrative and
/// world-mutating commands are available only through the loopback admin TCP
/// console, which is a separate trust boundary.
pub fn isPlayerConsoleCommand(verb: []const u8) bool {
    return eqAny(verb, &.{
        "help",        "commands",  "?",   "gettime", "gt",      "listplayers", "lp",
        "listents",    "le",        "say", "s",       "version", "dm",          "cm",
        "settempunit", "debugmenu",
    });
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

test "chatMsgOk length and control bounds" {
    try std.testing.expect(chatMsgOk("hello"));
    try std.testing.expect(!chatMsgOk(""));
    try std.testing.expect(!chatMsgOk("bad\nline"));
    try std.testing.expect(!chatMsgOk("x" ** (max_chat_msg_len + 1)));
    try std.testing.expect(chatMsgOk("x" ** max_chat_msg_len));
    try std.testing.expect(!chatMsgOk("del\x7f"));
}
