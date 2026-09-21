//! Console bodies: the server-command parse and the client-reply
//! builder, with the parse/roundtrip tests.
//!
//! Split out of the packages.zig facade (same code, same tests);
//! import via `packages.stock_console` like the other stock_* leaves.

const std = @import("std");
const binary = @import("binary.zig");

/// NetPackageConsoleCmdServer body = one .NET string (the command). Returns it
/// in `buf` (caller-owned). Empty on malformed.
pub fn parseConsoleCmd(body: []const u8, buf: []u8) []const u8 {
    var r: binary.Reader = .{ .data = body };
    return r.readString(buf) catch "";
}

/// NetPackageConsoleCmdClient body = i32 lineCount + lineCount .NET strings +
/// bool bExecute. Server sends command output back to the console.
pub fn buildConsoleCmdClient(buf: []u8, lines: []const []const u8, b_execute: bool) ![]u8 {
    var w: binary.Writer = .{ .buf = buf };
    try w.writeI32(@intCast(lines.len));
    for (lines) |ln| try w.writeString(ln);
    try w.writeBool(b_execute);
    return w.written();
}

test "console cmd parse + client reply roundtrip" {
    // Server-side: parse the command the client typed.
    var body: [64]u8 = undefined;
    var w: binary.Writer = .{ .buf = &body };
    try w.writeString("teleportplayer 10 70 20");
    const cmd_body = w.written();
    var cbuf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("teleportplayer 10 70 20", parseConsoleCmd(cmd_body, &cbuf));

    // Client reply: i32 count + strings + bool, readable by the stock client.
    var rbuf: [256]u8 = undefined;
    const lines = [_][]const u8{ "line one", "line two" };
    const reply = try buildConsoleCmdClient(&rbuf, &lines, false);
    var r: binary.Reader = .{ .data = reply };
    try std.testing.expectEqual(@as(i32, 2), try r.readI32());
    var lb: [64]u8 = undefined;
    try std.testing.expectEqualStrings("line one", try r.readString(&lb));
    try std.testing.expectEqualStrings("line two", try r.readString(&lb));
    try std.testing.expectEqual(false, try r.readBool());
}

test "console cmd parse handles empty/malformed" {
    var cbuf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("", parseConsoleCmd(&.{}, &cbuf));
    // Truncated payload (claimed length longer than remaining bytes).
    try std.testing.expectEqualStrings("", parseConsoleCmd(&[_]u8{ 5, 'h', 'i' }, &cbuf));
    // Overlong 7-bit length prefix (same rejection as binary.Reader).
    try std.testing.expectEqualStrings("", parseConsoleCmd(&[_]u8{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x00 }, &cbuf));
    // Valid short command still parses after the empty/malformed cases.
    var ok_body: [16]u8 = undefined;
    var w: binary.Writer = .{ .buf = &ok_body };
    try w.writeString("help");
    try std.testing.expectEqualStrings("help", parseConsoleCmd(w.written(), &cbuf));
}
