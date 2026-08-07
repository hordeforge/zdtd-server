//! Non-blocking TCP listen helper via Zig 0.16 `std.Io.net` listen + thin
//! posix accept/read/write. No `std.os.linux` in callers (admin, GSI, webui).
//!
//! Note: `Io.net.Server.accept` treats EAGAIN as a programmer bug when the
//! listen fd is non-blocking, so accept uses `posix.system.accept4` + poll.

const std = @import("std");
const Io = std.Io;
const net = Io.net;
const posix = std.posix;

pub const IpAddress = net.IpAddress;
pub const Handle = net.Socket.Handle;

pub const Listener = struct {
    io_impl: Io.Threaded = undefined,
    server: ?net.Server = null,
    port: u16 = 0,

    /// Bind IPv4 and listen. `host_be` host-order (0x7f000001 loopback, 0 = ANY).
    pub fn listen(self: *Listener, host_be: u32, port: u16, backlog: u31) !void {
        if (port == 0) return error.InvalidPort;
        self.io_impl = Io.Threaded.init(std.heap.page_allocator, .{});
        errdefer self.io_impl.deinit();
        const io_rt = self.io_impl.io();

        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, host_be, .big);
        const addr: IpAddress = .{ .ip4 = .{ .bytes = bytes, .port = port } };
        var srv = try addr.listen(io_rt, .{
            .kernel_backlog = backlog,
            .reuse_address = true,
            .mode = .stream,
            .protocol = .tcp,
        });
        errdefer srv.deinit(io_rt);

        self.server = srv;
        self.port = srv.socket.address.getPort();
    }

    pub fn deinit(self: *Listener) void {
        if (self.server) |*s| {
            s.deinit(self.io_impl.io());
            self.server = null;
            self.io_impl.deinit();
        }
        self.port = 0;
    }

    pub fn io(self: *Listener) Io {
        return self.io_impl.io();
    }

    pub fn enabled(self: *const Listener) bool {
        return self.server != null;
    }

    fn listenFd(self: *const Listener) ?Handle {
        const srv = self.server orelse return null;
        return srv.socket.handle;
    }

    /// Accept one connection without blocking. Null if none pending.
    pub fn accept(self: *Listener) !?Handle {
        const lfd = self.listenFd() orelse return null;

        // poll 0 ms: is a connection waiting?
        var pfd = [_]posix.pollfd{.{
            .fd = lfd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const nready = posix.poll(&pfd, 0) catch return null;
        if (nready == 0 or (pfd[0].revents & posix.POLL.IN) == 0) return null;

        var storage: posix.sockaddr.storage = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        // NONBLOCK|CLOEXEC on the new fd; listen stays blocking (poll gates us).
        const flags: u32 = posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;
        const rc = posix.system.accept4(lfd, @ptrCast(&storage), &addr_len, flags);
        const errn = posix.errno(rc);
        if (errn == .AGAIN) return null;
        if (errn != .SUCCESS) return error.AcceptFailed;
        return @intCast(rc);
    }
};

pub fn closeFd(fd: Handle) void {
    if (fd < 0) return;
    _ = posix.system.close(fd);
}

/// Non-blocking read. Returns 0 on EOF; error.WouldBlock if empty.
pub fn read(fd: Handle, buf: []u8) !usize {
    return posix.read(fd, buf) catch |err| switch (err) {
        error.WouldBlock => error.WouldBlock,
        else => error.ReadFailed,
    };
}

/// Best-effort full write (short writes retried until done, error, or timeout).
/// Never busy-spins on EAGAIN: poll POLLOUT so the sim/poll thread cannot pin a core.
pub fn writeAll(fd: Handle, data: []const u8) void {
    var off: usize = 0;
    // Cap total wait so a paused peer cannot stall the 20 TPS loop forever.
    const max_wait_ms: i32 = 200;
    var waited_ms: i32 = 0;
    while (off < data.len) {
        const rc = posix.system.write(fd, data[off..].ptr, data.len - off);
        const errn = posix.errno(rc);
        if (errn == .AGAIN) {
            if (waited_ms >= max_wait_ms) return;
            var pfd = [_]posix.pollfd{.{
                .fd = fd,
                .events = posix.POLL.OUT,
                .revents = 0,
            }};
            const slice_ms: i32 = 25;
            _ = posix.poll(&pfd, slice_ms) catch {};
            waited_ms += slice_ms;
            continue;
        }
        if (errn == .INTR) continue;
        if (errn != .SUCCESS or rc == 0) return;
        off += @intCast(rc);
    }
}

/// Host-order IPv4 of the bound listen address (test helper).
fn boundHostBe(self: *const Listener) !u32 {
    const srv = self.server orelse return error.NotListening;
    const ip4 = switch (srv.socket.address) {
        .ip4 => |a| a,
        .ip6 => return error.NotIpv4,
    };
    return std.mem.readInt(u32, &ip4.bytes, .big);
}

test "Listener loopback accept empty" {
    var L: Listener = .{};
    // High port unlikely to collide in CI; SkipZigTest (not silent pass) if bind fails.
    L.listen(0x7f000001, 19876, 4) catch return error.SkipZigTest;
    defer L.deinit();
    try std.testing.expect(L.enabled());
    try std.testing.expectEqual(@as(u16, 19876), L.port);
    try std.testing.expectEqual(@as(u32, 0x7f000001), try boundHostBe(&L));
    const h = try L.accept();
    try std.testing.expect(h == null);
}

test "Listener ANY bind is not loopback" {
    var L: Listener = .{};
    L.listen(0, 19879, 4) catch return error.SkipZigTest;
    defer L.deinit();
    try std.testing.expect(L.enabled());
    // 0.0.0.0 is distinct from 127.0.0.1 (admin/webui host selection relies on this).
    try std.testing.expectEqual(@as(u32, 0), try boundHostBe(&L));
}
