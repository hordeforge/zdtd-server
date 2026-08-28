//! UDP socket via Zig 0.16 `std.Io.net` (no raw `std.os.linux` syscalls).
//! Non-blocking poll: zero-duration Timeout → WouldBlock/Timeout.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const posix = std.posix;

pub const IpAddress = net.IpAddress;

pub const Socket = struct {
    io_impl: Io.Threaded = undefined,
    sock: ?net.Socket = null,
    /// Bound local address (includes resolved ephemeral port).
    local: IpAddress = undefined,

    pub fn openAndBind(self: *Socket, port: u16) !u16 {
        self.io_impl = Io.Threaded.init(std.heap.page_allocator, .{});
        errdefer self.io_impl.deinit();
        const io_rt = self.io_impl.io();

        // Dual-stack: bind IPv6 unspecified with V6ONLY=0 so both IPv4-mapped
        // and native IPv6 clients reach the server (stock LiteNetLib sets the
        // dual-stack flag). Fall back to IPv4-only when the host has no IPv6.
        var sock: net.Socket = undefined;
        var is6 = false;
        if ((IpAddress{ .ip6 = .unspecified(port) }).bind(io_rt, .{
            .mode = .dgram,
            .protocol = .udp,
        })) |s6| {
            sock = s6;
            is6 = true;
        } else |_| {
            const any4: IpAddress = .{ .ip4 = .unspecified(port) };
            sock = try any4.bind(io_rt, .{
                .mode = .dgram,
                .protocol = .udp,
            });
        }
        errdefer sock.close(io_rt);

        // SO_REUSEADDR: BindOptions has no reuse flag (listen-only); set via posix.
        const yes: c_int = 1;
        posix.setsockopt(
            sock.handle,
            posix.SOL.SOCKET,
            posix.SO.REUSEADDR,
            std.mem.asBytes(&yes),
        ) catch {};
        // Dual-stack on the v6 socket: accept v4-mapped addresses too. Best
        // effort: a kernel without dual-stack keeps a v6-only socket, which
        // still serves native IPv6 clients.
        if (is6) {
            const off: c_int = 0;
            // std.posix.setsockopt maps EINVAL to unreachable, but restricted
            // hosts return EINVAL for a post-bind V6ONLY=0; probe through the
            // errno-returning syscall instead and accept refusal either way.
            _ = posix.errno(posix.system.setsockopt(
                sock.handle,
                posix.IPPROTO.IPV6,
                posix.IPV6.V6ONLY,
                @ptrCast(&off),
                @sizeOf(c_int),
            ));
        }

        self.sock = sock;
        self.local = sock.address;
        return self.local.getPort();
    }

    pub fn close(self: *Socket) void {
        if (self.sock) |*s| {
            s.close(self.io_impl.io());
            self.sock = null;
            self.io_impl.deinit();
        }
    }

    pub fn io(self: *Socket) Io {
        return self.io_impl.io();
    }

    /// Non-blocking receive. On empty queue returns error.WouldBlock.
    /// Unbound socket (offline DST games never open one): also WouldBlock, so
    /// the poll loop sees a sealed network instead of a hard socket error.
    pub fn recvFrom(self: *Socket, buf: []u8, from_out: *IpAddress) !usize {
        const s = self.sock orelse return error.WouldBlock;
        const msg = s.receiveTimeout(self.io_impl.io(), buf, .{
            .duration = .{ .raw = .zero, .clock = .awake },
        }) catch |err| switch (err) {
            error.Timeout => return error.WouldBlock,
            else => return error.RecvFailed,
        };
        from_out.* = msg.from;
        return msg.data.len;
    }

    /// Unbound socket (offline DST games): drop silently and report success so
    /// the seeded sim never touches the network stack and outbound payloads
    /// still flow to the test Capture. Production sockets always bind first.
    pub fn sendTo(self: *Socket, data: []const u8, dest: *const IpAddress) !void {
        const s = self.sock orelse return;
        s.send(self.io_impl.io(), dest, data) catch return error.SendFailed;
    }
};

/// FNV-1a key for peer lookup (IPv4 addr+port; IPv6 first 16 bytes + port).
pub fn hashIp(addr: *const IpAddress) u64 {
    var h: u64 = 1469598103934665603;
    const mix = struct {
        fn byte(hh: *u64, b: u8) void {
            hh.* ^= b;
            hh.* *%= 1099511628211;
        }
    }.byte;
    switch (addr.*) {
        .ip4 => |a| {
            for (a.bytes) |b| mix(&h, b);
            mix(&h, @truncate(a.port));
            mix(&h, @truncate(a.port >> 8));
        },
        .ip6 => |a| {
            for (a.bytes) |b| mix(&h, b);
            mix(&h, @truncate(a.port));
            mix(&h, @truncate(a.port >> 8));
        },
    }
    return h;
}

test "hashIp stable for loopback" {
    const a: IpAddress = .{ .ip4 = .loopback(27015) };
    const b: IpAddress = .{ .ip4 = .loopback(27015) };
    try std.testing.expectEqual(hashIp(&a), hashIp(&b));
    const c: IpAddress = .{ .ip4 = .loopback(27016) };
    try std.testing.expect(hashIp(&a) != hashIp(&c));
}

test "openAndBind dual-stack round-trips a loopback datagram" {
    var s: Socket = .{};
    const port = try s.openAndBind(0);
    defer s.close();
    var rx: [64]u8 = undefined;
    var from: IpAddress = undefined;
    const v6 = s.local == .ip6;
    const dst: IpAddress = if (v6)
        .{ .ip6 = .loopback(port) }
    else
        .{ .ip4 = .loopback(port) };
    try s.sendTo("ping", &dst);
    const n = try s.recvFrom(&rx, &from);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expect(std.mem.eql(u8, rx[0..n], "ping"));
    // A dual-stack socket also accepts a native IPv6 client datagram.
    if (v6) {
        const v6dst: IpAddress = .{ .ip6 = .loopback(port) };
        try s.sendTo("v6", &v6dst);
        const n2 = try s.recvFrom(&rx, &from);
        try std.testing.expectEqual(@as(usize, 2), n2);
    }
}

test "unbound socket is sealed: recv WouldBlock, send drops" {
    // Offline DST games never bind; the sim must see a quiet network and
    // outbound payloads must still succeed (they flow to the test Capture).
    var s: Socket = .{};
    defer s.close();
    var rx: [64]u8 = undefined;
    var from: IpAddress = undefined;
    try std.testing.expectError(error.WouldBlock, s.recvFrom(&rx, &from));
    try s.sendTo("dropped", &.{ .ip4 = .loopback(1) });
}
