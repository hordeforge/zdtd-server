//! In-process test and scenario helpers for joined clients, packet injection,
//! replication, and direct world setup. Production networking does not use
//! these shortcuts.

const std = @import("std");
const game_mod = @import("../game.zig");
const Game = game_mod.Game;
const Client = game_mod.Client;
const wire_frame = @import("../../wire/frame.zig");
const wire_binary = @import("../../wire/binary.zig");
const packages = @import("../../wire/packages.zig");
const platform_user = packages.platform_user;
const version = @import("../../version.zig");

pub fn applyDamage(self: *Game, entity_id: i32, amount: f32) bool {
    return self.sim.damage(entity_id, amount).killed;
}

pub fn setBlock(self: *Game, x: i32, y: i32, z: i32, id: u16) !void {
    try self.world.setBlockWorld(x, y, z, id);
    if (self.isStorageBlockId(id)) {
        _ = self.containers.getOrCreate(.{ .x = x, .y = y, .z = z }, 8, @intCast(id));
    } else {
        self.containers.remove(.{ .x = x, .y = y, .z = z });
    }
}

pub fn attachJoinedClient(self: *Game, capture: ?*@import("../../litenet/peer.zig").Capture) !*Client {
    return attachJoinedClientAs(self, capture, null);
}

pub fn attachJoinedClientAs(self: *Game, capture: ?*@import("../../litenet/peer.zig").Capture, puid: ?platform_user.Id) !*Client {
    var peer_ptr: ?*@import("../../litenet/peer.zig").Peer = null;
    for (&self.net.peers) |*p| {
        if (p.alive) continue;
        p.* = .{};
        p.alive = true;
        p.local_id = self.net.next_local_id;
        self.net.next_local_id += 1;
        p.authenticated = false;
        p.capture = capture;
        const fake_port: u16 = @intCast(10000 + @as(u16, @intCast(p.local_id)));
        const addr: @import("../../litenet/udp_socket.zig").IpAddress = .{
            .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = fake_port },
        };
        p.setAddr(&addr);
        peer_ptr = p;
        break;
    }
    const peer = peer_ptr orelse return error.TooManyPeers;
    try self.onConnected(peer);
    const c = self.clientFor(peer) orelse return error.NoClient;
    var ch: [17]u8 = undefined;
    wire_frame.buildChallenge(&ch, c.challenge);
    try self.onData(peer, &ch);
    var login_body: [256]u8 = undefined;
    var w: wire_binary.Writer = .{ .buf = &login_body };
    try w.writeString("Bot");
    try platform_user.write(&w, puid);
    try w.writeString("");
    try platform_user.write(&w, puid);
    try w.writeString("");
    try w.writeString(version.stock_wire_comp);
    try w.writeString(version.stock_wire_comp);
    try w.writeU64(0);
    var frame_buf: [512]u8 = undefined;
    const framed = try packages.framed(&frame_buf, "NetPackagePlayerLogin", w.written());
    try self.onData(peer, framed);
    if (packages.idOf("NetPackageRequestToEnterGame")) |enter_id| {
        var enter_frame: [64]u8 = undefined;
        const ef = try wire_frame.framePackage(&enter_frame, 0, enter_id, &[_]u8{});
        try self.onData(peer, ef);
    }
    if (packages.idOf("NetPackageRequestToSpawnPlayer")) |spawn_id| {
        var spawn_body: [4]u8 = undefined;
        std.mem.writeInt(i16, spawn_body[0..2], 4, .little);
        var spawn_frame: [64]u8 = undefined;
        const sf = try wire_frame.framePackage(&spawn_frame, 0, spawn_id, spawn_body[0..2]);
        try self.onData(peer, sf);
    }
    if (!c.joined or c.entity_id <= 0) return error.JoinFailed;
    return c;
}

pub fn injectFramed(self: *Game, c: *Client, framed: []const u8) !void {
    const peer = c.peer orelse return error.NoPeer;
    try self.onData(peer, framed);
}

pub fn replicateNow(self: *Game) !void {
    try self.replicate();
}

pub fn handlePartyActions(self: *Game, c: *Client, body: []const u8) !void {
    return @import("social.zig").handlePartyActions(self, c, body);
}

pub fn acceptQuestFor(self: *Game, c: *Client, def_id: u16) bool {
    return @import("social.zig").acceptQuestFor(self, c, def_id);
}

pub fn handleAllyRequest(self: *Game, c: *Client, body: []const u8) !void {
    return @import("social.zig").handleAllyRequest(self, c, body);
}
