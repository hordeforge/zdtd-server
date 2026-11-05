//! Embeddable C ABI for the zdtd simulation (libzdtd).
//!
//! The exported surface is deliberately small: create a world, tick it, destroy
//! it, and read the last error. The world handle is opaque to C; state accessors
//! and snapshots are a later slice.
//!
//! Scope: a world here is the ECS simulation (`ecs.World` plus the schedule
//! pipeline). Networking, block storage, persistence and plugins belong to the
//! server executable and are not reachable from this ABI. The tick is the same
//! simulation tick the server runs, without the I/O around it.
//!
//! ABI rules:
//! - Every exported function is `callconv(.c)` and returns C-compatible types.
//! - `abi_version` must match `ZDTD_ABI_VERSION` in include/zdtd.h.
//! - Calls that cannot do their job return a nonzero status (or null) and set
//!   the last-error text. No exported call is a silent no-op.

const std = @import("std");
const ecs = @import("ecs/root.zig");

/// Version of the exported surface. Bump whenever a signature, a status value
/// or the ownership contract changes; include/zdtd.h states the same number.
pub const abi_version: u32 = 1; // Z: zdtd-owned C ABI contract; mirrors ZDTD_ABI_VERSION

/// Status values returned by `zdtd_tick`. Must match the ZDTD_* constants in
/// include/zdtd.h.
pub const Status = enum(i32) {
    ok = 0,
    invalid_argument = 1,
};

/// Opaque world handle. C only sees the forward declaration in include/zdtd.h.
pub const World = struct {
    allocator: std.mem.Allocator,
    sim: ecs.World,
};

/// Most recent error text for the calling thread. The C API has no world
/// argument on `zdtd_last_error`, so this is per-thread rather than per-world;
/// a caller that ticks several worlds on one thread reads the error for the
/// call that failed most recently on that thread.
const LastError = struct {
    const max_bytes = 256;
    threadlocal var text: [max_bytes]u8 = @splat(0);
    threadlocal var len: usize = 0;

    fn clear() void {
        len = 0;
        text[0] = 0;
    }

    fn set(comptime fmt: []const u8, args: anytype) void {
        // Reserve the last byte for the NUL: bufPrint does not add one.
        const msg = std.fmt.bufPrint(text[0 .. text.len - 1], fmt, args) catch {
            const fallback = "zdtd: error text truncated";
            @memcpy(text[0..fallback.len], fallback);
            len = fallback.len;
            text[len] = 0;
            return;
        };
        len = msg.len;
        text[len] = 0;
    }
};

/// Return the ABI version this archive was built with. Callers compare it with
/// ZDTD_ABI_VERSION from the header before using any other call.
pub export fn zdtd_abi_version() callconv(.c) u32 {
    return abi_version;
}

/// Create an empty simulation world. Returns null on allocation failure; the
/// reason is available from `zdtd_last_error`.
///
/// The library owns its allocator: C has no portable allocator ABI, so a caller
/// pointer could not be used safely. A later ABI version can add an explicit
/// allocator-vtable variant.
pub export fn zdtd_create() callconv(.c) ?*World {
    LastError.clear();
    const allocator = std.heap.page_allocator;
    const world = allocator.create(World) catch {
        LastError.set("zdtd_create: out of memory allocating the world", .{});
        return null;
    };
    world.* = .{ .allocator = allocator, .sim = .{} };
    world.sim.ensureNetMap(allocator) catch {
        allocator.destroy(world);
        LastError.set("zdtd_create: out of memory allocating the net id map", .{});
        return null;
    };
    return world;
}

/// Destroy a world created by `zdtd_create`. A null handle is ignored.
pub export fn zdtd_destroy(world: ?*World) callconv(.c) void {
    const w = world orelse return;
    w.sim.deinit();
    w.allocator.destroy(w);
}

/// Advance the simulation one tick with `delta_seconds` of simulated time.
///
/// Returns ZDTD_OK (0) on success. A null handle, or a delta that is not
/// finite, is not greater than zero, or exceeds one second, returns
/// ZDTD_ERR_INVALID_ARGUMENT (1) and sets the error text; the world is not
/// advanced in that case. The one-second cap is twenty fixed 50 ms ticks, far
/// wider than any honest caller needs, and keeps absurd input out of the sim.
pub export fn zdtd_tick(world: ?*World, delta_seconds: f32) callconv(.c) i32 {
    const max_tick_seconds: f32 = 1.0;
    const w = world orelse {
        LastError.set("zdtd_tick: world handle is NULL", .{});
        return @intFromEnum(Status.invalid_argument);
    };
    if (!std.math.isFinite(delta_seconds) or delta_seconds <= 0 or delta_seconds > max_tick_seconds) {
        LastError.set(
            "zdtd_tick: delta_seconds must be finite, greater than zero and at most one second (got {d})",
            .{delta_seconds},
        );
        return @intFromEnum(Status.invalid_argument);
    }
    _ = ecs.schedule.run(&w.sim, delta_seconds);
    LastError.clear();
    return @intFromEnum(Status.ok);
}

/// Copy the last error text for the calling thread into `buffer`, NUL
/// terminated when `length` is nonzero. Returns the full message length
/// excluding the terminator, so a caller can size a retry buffer. Returns 0
/// when the last call succeeded. With a null `buffer` or `length == 0` nothing
/// is written and the required length is still returned.
pub export fn zdtd_last_error(buffer: ?[*]u8, length: usize) callconv(.c) usize {
    const msg = LastError.text[0..LastError.len];
    const out = buffer orelse return msg.len;
    if (length == 0) return msg.len;
    const n = @min(msg.len, length - 1);
    @memcpy(out[0..n], msg[0..n]);
    out[n] = 0;
    return msg.len;
}

test "abi version is the value the header promises" {
    try std.testing.expectEqual(@as(u32, 1), zdtd_abi_version());
}

test "create, tick, destroy" {
    const world = zdtd_create() orelse return error.OutOfMemory;
    defer zdtd_destroy(world);
    try std.testing.expectEqual(@intFromEnum(Status.ok), zdtd_tick(world, 0.05));
    try std.testing.expectEqual(@intFromEnum(Status.ok), zdtd_tick(world, 0.05));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), zdtd_last_error(&buf, buf.len));
}

test "tick rejects invalid delta and explains why" {
    const world = zdtd_create() orelse return error.OutOfMemory;
    defer zdtd_destroy(world);

    try std.testing.expectEqual(@intFromEnum(Status.invalid_argument), zdtd_tick(world, 0));
    var buf: [256]u8 = undefined;
    const n = zdtd_last_error(&buf, buf.len);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.startsWith(
        u8,
        buf[0..n],
        "zdtd_tick: delta_seconds must be finite, greater than zero and at most one second",
    ));

    try std.testing.expectEqual(@intFromEnum(Status.invalid_argument), zdtd_tick(world, std.math.nan(f32)));
    try std.testing.expectEqual(@intFromEnum(Status.invalid_argument), zdtd_tick(world, -0.05));
    try std.testing.expectEqual(@intFromEnum(Status.invalid_argument), zdtd_tick(world, 1.5));
}

test "last error reports the required length and truncates safely" {
    const world = zdtd_create() orelse return error.OutOfMemory;
    defer zdtd_destroy(world);
    try std.testing.expectEqual(@intFromEnum(Status.invalid_argument), zdtd_tick(world, 0));

    var tiny: [4]u8 = undefined;
    const needed = zdtd_last_error(&tiny, tiny.len);
    try std.testing.expect(needed > tiny.len - 1);
    try std.testing.expectEqual(@as(u8, 0), tiny[tiny.len - 1]);
    try std.testing.expectEqual(needed, zdtd_last_error(&tiny, 0));
    try std.testing.expectEqual(needed, zdtd_last_error(null, 0));
}

test "destroy accepts a null handle" {
    zdtd_destroy(null);
}
