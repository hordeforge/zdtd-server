//! LiteNetLib-compatible UDP transport (peers, packets, linux UDP batch).
//!
//! Dependency direction: lowest network layer. May import util (clock). Must
//! not import server, game packages, ecs, world, assets, or apm. Peer Capture
//! test helpers still reach wire/frame for package parse (test-only). Socket
//! path is intentional legacy `std.os.linux` until a deliberate net migration
//! (see AGENTS.md).

pub const server = @import("server.zig");
pub const peer = @import("peer.zig");
pub const packet = @import("packet.zig");
pub const linux_udp = @import("linux_udp.zig");

pub const Server = server.Server;
pub const Peer = peer.Peer;
pub const max_peers = server.max_peers;

test {
    _ = server;
    _ = peer;
    _ = packet;
    _ = linux_udp;
}
