//! Core plugin shared support: bounded output buffer, host imports, and the
//! `_zdtd_requires` export shape (ADR 0030). Imported by each plugin's root
//! file at build time; nothing here touches the wire or allocates.
//!
//! All core plugins are Zig (freestanding wasm32); bot stays C by design
//! (ADR 0026). Build recipe per plugin:
//!   zig build-exe -OReleaseSmall -target wasm32-freestanding -rdynamic \
//!     --name <name> -femit-bin=<name>.wasm <plugin>_main.zig
//! where `<plugin>_main.zig` is a two-line wrapper exporting `_start` and
//! pulling in the plugin root (zig build-exe needs an entry; zwasm runs the
//! start section only if declared, and we never declare one).

const std = @import("std");

pub extern "zdtd" fn log(level: i32, ptr: i32, len: i32) void;
pub extern "zdtd" fn tick() i64;
pub extern "zdtd" fn queue(ptr: i32, len: i32) i32;
pub extern "zdtd" fn sense(ptr: i32, len: i32, token: i32) i32;
pub extern "zdtd" fn query(req_ptr: i32, req_len: i32, out_ptr: i32, out_cap: i32) i32;
pub extern "zdtd" fn json_parse(ptr: i32, len: i32) i32;
pub extern "zdtd" fn json_str(path_ptr: i32, path_len: i32, out_ptr: i32, out_cap: i32) i32;
pub extern "zdtd" fn json_raw(path_ptr: i32, path_len: i32, out_ptr: i32, out_cap: i32) i32;
pub extern "zdtd" fn json_obj(path_ptr: i32, path_len: i32) i32;

/// Maximum bytes of one log line / queued command this module builds.
pub const out_cap = 160;

/// Bounded append buffer over a static array. Overflow drops bytes but keeps
/// counting so callers can detect truncation.
pub const Buf = struct {
    bytes: [out_cap]u8 = undefined,
    n: usize = 0,

    pub fn reset(self: *Buf) void {
        self.n = 0;
    }

    pub fn put(self: *Buf, s: []const u8) void {
        const room = out_cap - 1 - @min(self.n, out_cap - 1);
        const take = @min(s.len, room);
        // out_cap is tiny; the copy can never exceed the remaining slice.
        if (take > 0) {
            @memcpy(self.bytes[self.n..][0..take], s[0..take]);
            self.n += take;
        }
    }

    pub fn putInt(self: *Buf, v: anytype) void {
        var tmp: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return;
        self.put(s);
    }

    pub fn slice(self: *const Buf) []const u8 {
        return self.bytes[0..self.n];
    }

    pub fn logLine(self: *const Buf, level: i32) void {
        if (self.n == 0) return;
        log(level, @intCast(@intFromPtr(&self.bytes)), @intCast(self.n));
    }

    pub fn send(self: *const Buf) i32 {
        return queue(@intCast(@intFromPtr(&self.bytes)), @intCast(self.n));
    }
};

/// `_zdtd_requires` export (ADR 0030): low 32 bits ptr, high 32 bits len.
/// `spec` must be a comptime comma-separated capability list. Call from a
/// `comptime` block in the plugin root: `common.exportRequires("log,queue");`
pub fn exportRequires(comptime spec: []const u8) void {
    const S = struct {
        const text = spec;
        fn requires_spec() callconv(.c) i64 {
            const len: u64 = text.len;
            const ptr: u64 = @intFromPtr(text.ptr);
            return @bitCast(ptr | (len << 32));
        }
    };
    @export(&S.requires_spec, .{ .name = "_zdtd_requires" });
}

test "Buf truncates instead of overrunning" {
    var b: Buf = .{};
    const big = [_]u8{'x'} ** 200;
    b.put(&big);
    try std.testing.expectEqual(out_cap - 1, b.slice().len);
}
