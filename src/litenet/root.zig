//! LiteNetLib-compatible UDP transport (peers, packets, std.Io.net UDP).
//!
//! Dependency direction: lowest network layer. May import util (clock). Must
//! not import server, game packages, ecs, world, assets, or apm. Exception:
//! `peer.Capture` (scenario / unit harness only) imports wire/frame so capture
//! can decode package ids by name. Production send/recv paths stay wire-free.
//! Sockets use `std.Io.net` + `std.posix.setsockopt` (AGENTS rule 24).

pub const server = @import("server.zig");
pub const peer = @import("peer.zig");
pub const packet = @import("packet.zig");
pub const udp_socket = @import("udp_socket.zig");

pub const Server = server.Server;
pub const Peer = peer.Peer;
pub const max_peers = server.max_peers;

test {
    _ = server;
    _ = peer;
    _ = packet;
    _ = udp_socket;
}
