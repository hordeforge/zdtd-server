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

        const any: IpAddress = .{ .ip4 = .unspecified(port) };
        var sock = try any.bind(io_rt, .{
            .mode = .dgram,
            .protocol = .udp,
        });
        errdefer sock.close(io_rt);

        // SO_REUSEADDR: BindOptions has no reuse flag (listen-only); set via posix.
        const yes: c_int = 1;
        posix.setsockopt(
            sock.handle,
            posix.SOL.SOCKET,
            posix.SO.REUSEADDR,
            std.mem.asBytes(&yes),
        ) catch {};

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
    pub fn recvFrom(self: *Socket, buf: []u8, from_out: *IpAddress) !usize {
        const s = self.sock orelse return error.RecvFailed;
        const msg = s.receiveTimeout(self.io_impl.io(), buf, .{
            .duration = .{ .raw = .zero, .clock = .awake },
        }) catch |err| switch (err) {
            error.Timeout => return error.WouldBlock,
            else => return error.RecvFailed,
        };
        from_out.* = msg.from;
        return msg.data.len;
    }

    pub fn sendTo(self: *Socket, data: []const u8, dest: *const IpAddress) !void {
        const s = self.sock orelse return error.SendFailed;
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
