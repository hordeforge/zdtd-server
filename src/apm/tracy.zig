//! Optional Tracy client bindings, off by default.
//!
//! Tracy is NOT vendored and is NOT a Zig package dependency. The client is
//! built only when the operator passes `-Dtracy=true -Dtracy-src=PATH`, where
//! PATH is a Tracy checkout containing `public/TracyClient.cpp`. With the flag
//! off, `Zone` is zero-sized, none of the `extern` decls below are referenced,
//! and nothing links.
//!
//! ABI lock: `ZoneCtx` mirrors `___tracy_c_zone_context` from
//! `public/tracy/TracyC.h` for a client compiled WITHOUT `TRACY_ON_DEMAND`.
//! That macro appends a `uint64_t connectionId` to the struct, which is
//! returned by value from `___tracy_emit_zone_begin`. build.zig owns the C flag
//! list and never defines it, so the two cannot drift in-tree.
//!
//! Dependency direction: std + `build_options` only. See src/apm/root.zig.

const std = @import("std");
const build_options = @import("build_options");

/// True only for an opt-in `-Dtracy=true` profiling build.
pub const enabled = build_options.tracy_enabled;

/// Mirror of `___tracy_source_location_data`. Must outlive every zone that
/// points at it, so instances live in rodata (container-level consts).
pub const SourceLocation = extern struct {
    name: ?[*:0]const u8,
    function: [*:0]const u8,
    file: [*:0]const u8,
    line: u32,
    color: u32 = 0,
};

const ZoneCtx = extern struct { id: u32, active: i32 };

extern fn ___tracy_emit_zone_begin(srcloc: *const SourceLocation, active: c_int) ZoneCtx;
extern fn ___tracy_emit_zone_end(ctx: ZoneCtx) void;
extern fn ___tracy_emit_frame_mark(name: ?[*:0]const u8) void;

/// Open zone handle. Zero-sized when Tracy is off.
pub const Zone = struct {
    ctx: if (enabled) ZoneCtx else void,

    pub inline fn end(self: Zone) void {
        if (enabled) ___tracy_emit_zone_end(self.ctx);
    }
};

/// Begin a zone. `active = false` emits an inactive (allocation-free no-op)
/// zone: the Tracy client returns early on both begin and end, so the pair
/// still nests correctly without fabricating a name.
pub inline fn zone(loc: *const SourceLocation, active: bool) Zone {
    return .{ .ctx = if (enabled) ___tracy_emit_zone_begin(loc, @intFromBool(active)) else {} };
}

/// Close the current (unnamed, default) Tracy frame. One call per server tick.
pub inline fn frameMark() void {
    if (enabled) ___tracy_emit_frame_mark(null);
}

test "tracy off costs nothing" {
    if (enabled) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(Zone));
    // The disabled path must still be callable and must not reference any
    // extern symbol (this test binary links no Tracy client).
    const loc: SourceLocation = .{ .name = "test", .function = "test", .file = "tracy.zig", .line = 1 };
    zone(&loc, true).end();
    zone(&loc, false).end();
    frameMark();
}
