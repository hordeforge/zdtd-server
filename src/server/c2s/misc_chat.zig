//! C2S chat packages: NetPackageChat / NetPackageSimpleChat.
//!
//! Split out of c2s/misc.zig (same code, moved verbatim).

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const ln_peer = @import("../../litenet/peer.zig");
const packages = @import("../../wire/packages.zig");
const wire_binary = @import("../../wire/binary.zig");
const c2s_text = @import("../c2s_text.zig");
const max_chat_msg_len = c2s_text.max_chat_msg_len;
const chatMsgOk = c2s_text.chatMsgOk;
const plugin_compose = @import("../game/plugin_compose.zig");
const log = @import("../../util/log.zig");

pub fn filteredChatText(self: *Game, c: *Client, msg: []const u8, native_buf: []u8, wasm_buf: []u8) ?[]const u8 {
    if (plugin_compose.chatFilter(self, c.entity_id, msg, native_buf, wasm_buf)) |f| {
        if (f.len == 0) return null;
        if (!chatMsgOk(f)) return null;
        return f;
    }
    return msg;
}

/// True when `name` is a chat package and was handled.
pub fn handleChat(self: *Game, c: *Client, peer: *ln_peer.Peer, name: []const u8, body: []const u8) anyerror!bool {
    _ = peer;
    if (std.mem.eql(u8, name, "NetPackageChat") or std.mem.eql(u8, name, "NetPackageSimpleChat")) {
        if (!self.acceptChatRate(c)) return true;
        if (std.mem.eql(u8, name, "NetPackageChat")) {
            const ch = packages.parseStockChat(body) catch return true;
            if (!chatMsgOk(ch.msg)) return true;
            var chat_buf: [c2s_text.max_chat_msg_len]u8 = undefined;
            var wasm_buf: [c2s_text.max_chat_msg_len]u8 = undefined;
            const chat_msg = filteredChatText(self, c, ch.msg, &chat_buf, &wasm_buf) orelse return true;
            const stock = packages.buildStockChat(
                self.body_buf[0..512],
                ch.chat_type,
                c.entity_id,
                chat_msg,
                ch.recipients[0..ch.recipient_count],
            ) catch return true;
            // The sender is included, in both directions. Stock's client does
            // not add its own line locally: XUiC_Chat sends to the server and
            // waits for the echo, and it puts its own entity id first in the
            // party recipient list (XUiC_Chat.il.txt:212-223). The server
            // broadcast passes allBut = -1 and the targeted loop sends to
            // every listed ClientInfo, neither excluding the speaker
            // (GameManager.il.txt:7690-7735). Excluding them here meant a
            // player never saw their own messages.
            if (ch.recipient_count > 0) {
                for (ch.recipients[0..ch.recipient_count]) |rid| {
                    if (self.clientByEntityId(rid)) |rc| {
                        if (rc.peer) |rpeer| {
                            self.sendGame(rpeer, "NetPackageChat", stock) catch |err| {
                                self.harness.counters.inc(.net_send_errors);
                                log.err("send chat failed: {s}\n", .{@errorName(err)});
                            };
                        }
                    }
                }
            } else {
                try self.broadcast("NetPackageChat", stock);
            }
        } else {
            var r: wire_binary.Reader = .{ .data = body };
            var from_buf: [64]u8 = undefined;
            var msg_buf: [max_chat_msg_len]u8 = undefined;
            // Sender name: read to advance the reader, then discard.
            _ = r.readString(&from_buf) catch "";
            const msg = r.readString(&msg_buf) catch return true;
            if (!chatMsgOk(msg)) return true;
            var chat_buf2: [c2s_text.max_chat_msg_len]u8 = undefined;
            var wasm_buf2: [c2s_text.max_chat_msg_len]u8 = undefined;
            const chat_msg = filteredChatText(self, c, msg, &chat_buf2, &wasm_buf2) orelse return true;
            const stock = try packages.buildStockChat(self.body_buf[0..512], 0, c.entity_id, chat_msg, &.{});
            try self.broadcast("NetPackageChat", stock);
        }
        return true;
    }
    return false;
}
