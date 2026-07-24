//! Thin Linux UDP helpers for Zig 0.16 (no high-level posix.socket).

const std = @import("std");
const linux = std.os.linux;

pub const Socket = struct {
    fd: i32 = -1,

    pub fn open() !Socket {
        const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return error.SocketCreateFailed;
        return .{ .fd = @intCast(rc) };
    }

    pub fn close(self: *Socket) void {
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
            self.fd = -1;
        }
    }

    pub fn bindAny(self: *Socket, port: u16) !u16 {
        var yes: c_int = 1;
        _ = linux.setsockopt(self.fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&yes), @sizeOf(c_int));
        var addr = linux.sockaddr.in{
            .family = linux.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = 0,
        };
        const br = linux.bind(self.fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
        if (linux.errno(br) != .SUCCESS) return error.BindFailed;
        var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        _ = linux.getsockname(self.fd, @ptrCast(&addr), &len);
        return std.mem.bigToNative(u16, addr.port);
    }

    pub fn recvFrom(self: *Socket, buf: []u8, src: *linux.sockaddr.storage, src_len: *linux.socklen_t) !usize {
        src_len.* = @sizeOf(linux.sockaddr.storage);
        const rc = linux.recvfrom(self.fd, buf.ptr, buf.len, 0, @ptrCast(src), src_len);
        const err = linux.errno(rc);
        // On Linux EAGAIN and EWOULDBLOCK are the same value; Zig's E only has AGAIN.
        if (err == .AGAIN) return error.WouldBlock;
        if (err != .SUCCESS) return error.RecvFailed;
        return @intCast(rc);
    }

    pub fn sendTo(self: *Socket, data: []const u8, dest: *const linux.sockaddr.storage, dest_len: linux.socklen_t) !void {
        const rc = linux.sendto(self.fd, data.ptr, data.len, 0, @ptrCast(dest), dest_len);
        if (linux.errno(rc) != .SUCCESS) return error.SendFailed;
    }
};
